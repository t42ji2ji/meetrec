import AVFoundation
import Foundation

/// 錄音資料夾的內容與操作：列出錄音、排隊轉逐字稿（含進度）、匯入、改名、刪除。畫面只透過這裡動檔案。
/// 一場錄音一個資料夾：<folder>/<標題>/<標題>.m4a（＋ .srt、.txt、隱藏的逐字稿 json）。
@MainActor
final class Library: ObservableObject {
    static let shared = Library()
    let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Music/會議錄音")

    struct Recording: Identifiable, Hashable {
        /// 音檔
        let url: URL
        let date: Date
        let duration: Double // 秒
        var id: URL { url }
        /// 這場錄音的資料夾
        var folder: URL { url.deletingLastPathComponent() }
        var title: String { folder.lastPathComponent }
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
    /// 主動開始錄音：有瀏覽器在開會就錄它，沒有就只錄麥克風（AppDelegate 設定）
    var startLive: () -> Void = {}
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
        let fm = FileManager.default
        let entries = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles)) ?? []
        // 直接放在根目錄的音檔（舊版錄音、從 Finder 丟進來的）搬進自己的資料夾
        for url in entries where Self.audioTypes.contains(url.pathExtension.lowercased()) {
            Self.adopt(url, into: folder)
        }
        let live = recordingFile?.standardizedFileURL
        let known = Dictionary(uniqueKeysWithValues: recordings.map { ($0.url, $0) })
        let dirs = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles)) ?? []
        recordings = dirs
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .compactMap { dir in
                // 優先跟資料夾同名的音檔
                let audio = ((try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? [])
                    .filter { Self.audioTypes.contains($0.pathExtension.lowercased()) }
                    .sorted { a, _ in a.deletingPathExtension().lastPathComponent == dir.lastPathComponent }
                return audio.first
            }
            .filter { $0.standardizedFileURL != live }
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

    /// 根目錄的音檔連同同名的 srt、txt、逐字稿搬進新資料夾
    nonisolated private static func adopt(_ audio: URL, into root: URL) {
        guard let dest = try? Recorder.newURL(in: root, name: audio.deletingPathExtension().lastPathComponent)
            .deletingPathExtension().appendingPathExtension(audio.pathExtension) else { return }
        for (from, to) in zip(related(audio), related(dest)) where FileManager.default.fileExists(atPath: from.path) {
            try? FileManager.default.moveItem(at: from, to: to)
        }
    }

    /// 複製進錄音資料夾（自己一個資料夾）後轉逐字稿；影片之類 AVFoundation 能讀但不是純音檔的，抽出聲音轉成 m4a
    func importFiles(_ urls: [URL]) {
        let root = folder
        for src in urls {
            DispatchQueue.global().async {
                let ext = src.pathExtension.lowercased()
                let playable = Self.audioTypes.contains(ext)
                do {
                    let dest = try Recorder.newURL(in: root, name: src.deletingPathExtension().lastPathComponent)
                        .deletingPathExtension().appendingPathExtension(playable ? ext : "m4a")
                    if playable {
                        try FileManager.default.copyItem(at: src, to: dest)
                    } else {
                        try Media.convertToM4A(src, to: dest)
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

    /// 改名：資料夾和裡面的音檔、逐字稿、srt、txt 一起改。回傳新的音檔位置
    @discardableResult
    func rename(_ r: Recording, to title: String) throws -> URL {
        try rename(audio: r.url, to: title)
    }

    @discardableResult
    func rename(audio: URL, to title: String) throws -> URL {
        let title = title.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        let oldFolder = audio.deletingLastPathComponent()
        let newFolder = folder.appendingPathComponent(title)
        guard !title.isEmpty, newFolder.lastPathComponent != oldFolder.lastPathComponent else { return audio }
        let fm = FileManager.default
        guard !fm.fileExists(atPath: newFolder.path) else { throw LibraryError.nameTaken(title) }
        try fm.moveItem(at: oldFolder, to: newFolder)
        let moved = newFolder.appendingPathComponent(audio.lastPathComponent)
        let dest = newFolder.appendingPathComponent(title).appendingPathExtension(audio.pathExtension)
        for (from, to) in zip(Self.related(moved), Self.related(dest)) where fm.fileExists(atPath: from.path) {
            try fm.moveItem(at: from, to: to)
        }
        if let s = status.removeValue(forKey: audio) { status[dest] = s }
        reload()
        return dest
    }

    /// 整個資料夾丟到垃圾桶
    func delete(_ r: Recording) throws {
        try FileManager.default.trashItem(at: r.folder, resultingItemURL: nil)
        status[r.url] = nil
        reload()
    }

    /// 音檔、逐字稿 json、srt、txt
    nonisolated static func related(_ audio: URL) -> [URL] {
        let base = audio.deletingPathExtension()
        return [audio, Transcript.sidecar(for: audio), base.appendingPathExtension("srt"), base.appendingPathExtension("txt")]
    }

}

enum LibraryError: Error, CustomStringConvertible {
    case nameTaken(String)
    var description: String {
        switch self {
        case .nameTaken(let n): return L("已經有叫「\(n)」的錄音", "A recording named “\(n)” already exists")
        }
    }
}
