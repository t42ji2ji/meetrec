import AppKit
import AVFoundation
import Combine
import MediaToolbox
import UniformTypeIdentifiers

enum DashboardSelection: Hashable {
    case live
    case recording(URL)
}

/// 主視窗的狀態：選了哪一場、搜尋、正在編的逐字稿、播放器，以及改名／刪除／匯出這些動作
@MainActor
final class DashboardModel: ObservableObject {
    let library = Library.shared
    let player = DashboardPlayer()

    /// 側邊欄選到的
    @Published var selection: DashboardSelection? {
        didSet { if !picking { shown = selection } }
    }
    /// 右邊正在顯示的。程式設定 selection 時同步跟上；使用者在清單上點選時晚一輪（見 pick）
    @Published private(set) var shown: DashboardSelection? {
        didSet { if shown != oldValue { selectionChanged() } }
    }
    private var picking = false
    @Published var search = ""
    /// 選到的錄音有逐字稿時才有
    @Published private(set) var editor: TranscriptEditor?
    // 要確認的動作（畫面用 alert 呈現）
    @Published var renaming: Library.Recording?
    @Published var deleting: Library.Recording?
    @Published var retranscribing: Library.Recording?
    @Published var error: String?
    /// 檔案拖到視窗上方
    @Published var dropTargeted = false
    /// ⌘F：把焦點移到搜尋框（搜尋框建立時設定）
    var focusSearch: () -> Void = {}
    /// Library.status 的副本：畫面只看這個，不直接觀察 Library（錄音中每秒更新的 live 不會讓右邊整個重畫）
    @Published private(set) var status: [URL: Library.Status] = [:]

    /// 讀過的逐字稿，用檔案修改時間判斷還能不能用；切換錄音時不用再讀檔解析
    private var transcripts: [URL: (modified: Date, transcript: Transcript)] = [:]
    /// 搜尋用的逐字稿全文，逐字稿有存檔就整個丟掉重讀
    private var texts: [URL: (text: String, folded: String)] = [:]
    /// 等新檔案出現就選它（錄音存檔、匯入）
    private var awaitingNewFrom: Set<URL>?
    private var bag = Set<AnyCancellable>()

    init() {
        library.$status.removeDuplicates().assign(to: &$status)
        library.$revision.dropFirst().sink { [weak self] _ in
            self?.texts = [:]
            self?.refreshEditor()
        }.store(in: &bag)
        // @Published 在 willSet 送出，等這一輪跑完 library.recordings 才是新的
        library.$recordings.receive(on: RunLoop.main).sink { [weak self] list in
            self?.recordingsChanged(list)
            self?.prefetch(list)
        }.store(in: &bag)
        library.$live.removeDuplicates { ($0 == nil) == ($1 == nil) }.dropFirst().sink { [weak self] live in
            guard let self, live == nil else { return }
            // 錄音結束：選著錄音中那一列的話，等存好的檔案出現就跳過去
            if selection == .live { awaitingNewFrom = Set(library.recordings.map(\.url)) }
        }.store(in: &bag)
    }

    var selectedRecording: Library.Recording? {
        guard case .recording(let url) = shown else { return nil }
        return library.recordings.first { $0.url == url }
    }

    // MARK: 清單與搜尋

    var visibleRecordings: [Library.Recording] {
        let q = Self.fold(search.trimmingCharacters(in: .whitespaces))
        guard !q.isEmpty else { return library.recordings }
        return library.recordings.filter { Self.fold($0.title).contains(q) || text(of: $0).folded.contains(q) }
    }

    /// 搜尋字出現在逐字稿裡時，清單上顯示的前後文
    func snippet(for r: Library.Recording) -> String? {
        let q = Self.fold(search.trimmingCharacters(in: .whitespaces))
        guard !q.isEmpty, !Self.fold(r.title).contains(q) else { return nil }
        let (text, folded) = text(of: r)
        guard let range = folded.range(of: q) else { return nil }
        // 繁簡轉換是一字對一字，位置可以直接對回原文
        let source = text.count == folded.count ? text : folded
        let lower = folded.distance(from: folded.startIndex, to: range.lowerBound)
        let upper = folded.distance(from: folded.startIndex, to: range.upperBound)
        let start = source.index(source.startIndex, offsetBy: max(0, lower - 12))
        let end = source.index(source.startIndex, offsetBy: min(source.count, upper + 30))
        return (lower > 12 ? "…" : "") + source[start..<end].replacingOccurrences(of: "\n", with: " ")
    }

    /// whisper 有時候吐簡體字：比對前都轉成簡體、小寫
    private static func fold(_ s: String) -> String {
        (s.applyingTransform(StringTransform("Hant-Hans"), reverse: false) ?? s).lowercased()
    }

    private func text(of r: Library.Recording) -> (text: String, folded: String) {
        if let t = texts[r.url] { return t }
        let text = transcript(for: r.url)?.segments.map(\.text).joined(separator: "\n") ?? ""
        let t = (text, Self.fold(text))
        texts[r.url] = t
        return t
    }

    func hasTranscript(_ r: Library.Recording) -> Bool {
        FileManager.default.fileExists(atPath: Transcript.sidecar(for: r.url).path)
    }

    // MARK: 選取

    /// 使用者在清單上點選：反白先變（這一輪畫面只有清單在動），下一輪才換右邊的內容，點下去馬上有反應。
    /// 連按方向鍵時中間跳過的不會畫
    func pick(_ s: DashboardSelection?) {
        picking = true
        selection = s
        picking = false
        // async 會在同一輪跑完、跟反白擠在同一次畫面更新；用計時器排到畫完之後的下一輪
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.001) { [weak self] in
            guard let self, selection == s else { return }
            shown = s
        }
    }

    private func selectionChanged() {
        editor?.flush()
        editor = nil
        refreshEditor()
        if let r = selectedRecording {
            player.load(r.url, duration: r.duration)
        } else {
            player.unload()
        }
    }

    private func recordingsChanged(_ list: [Library.Recording]) {
        if let old = awaitingNewFrom, let new = list.first(where: { !old.contains($0.url) }) {
            awaitingNewFrom = nil
            selection = .recording(new.url)
        } else if editor == nil || player.url == nil, let r = selectedRecording {
            // 選的檔案剛出現（例如剛存好的錄音）
            if player.url == nil { player.load(r.url, duration: r.duration) }
            refreshEditor()
        }
    }

    /// 快取裡的逐字稿；檔案改過（存檔、重新轉錄）就重讀
    private func transcript(for url: URL) -> Transcript? {
        let file = Transcript.sidecar(for: url)
        guard let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate else {
            transcripts[url] = nil
            return nil
        }
        if let c = transcripts[url], c.modified == modified { return c.transcript }
        let t = Transcript.load(for: url)
        transcripts[url] = t.map { (modified, $0) }
        return t
    }

    /// 背景先把還沒讀過的逐字稿解析好，第一次點到也不用在主執行緒讀檔
    private func prefetch(_ list: [Library.Recording]) {
        let urls = list.prefix(50).map(\.url).filter { transcripts[$0] == nil }
        guard !urls.isEmpty else { return }
        Task.detached(priority: .utility) {
            for url in urls {
                let file = Transcript.sidecar(for: url)
                guard let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
                      let t = Transcript.load(for: url) else { continue }
                await MainActor.run { [weak self] in
                    if self?.transcripts[url] == nil { self?.transcripts[url] = (modified, t) }
                }
            }
        }
    }

    /// 讀磁碟上的逐字稿；同一場就交給 editor 判斷要不要換（自己存的不換，重新轉錄的換）
    private func refreshEditor() {
        guard let r = selectedRecording, let t = transcript(for: r.url) else {
            editor = nil
            return
        }
        if let editor, editor.recording.url == r.url {
            editor.adopt(t)
        } else {
            editor = TranscriptEditor(recording: r, transcript: t, clock: player.clock) { [weak self] in self?.error = $0 }
        }
    }

    func windowClosed() {
        editor?.flush()
        player.pause()
    }

    // MARK: 動作

    func rename(_ r: Library.Recording, to title: String) {
        if editor?.recording.url == r.url { editor?.flush() }
        do {
            let url = try library.rename(r, to: title)
            guard url != r.url else { return }
            if player.url == r.url { player.moved(to: url) }
            if selection == .recording(r.url) { selection = .recording(url) }
        } catch {
            self.error = "\(error)"
        }
    }

    func delete(_ r: Library.Recording) {
        let selected = shown == .recording(r.url)
        let list = visibleRecordings
        if selected {
            editor = nil
            player.unload()
        }
        do {
            try library.delete(r)
        } catch {
            self.error = "\(error)"
            return
        }
        // 選下一筆（沒有就上一筆），不要讓右邊空掉
        if selected, let i = list.firstIndex(of: r) {
            let rest = list.filter { $0 != r }
            selection = rest.isEmpty ? nil : .recording(rest[min(i, rest.count - 1)].url)
        }
    }

    func transcribe(_ r: Library.Recording) {
        if editor?.recording.url == r.url { editor?.discardPending() }
        library.transcribe(r.url)
    }

    func reveal(_ r: Library.Recording) {
        NSWorkspace.shared.activateFileViewerSelecting([r.folder])
    }

    enum ExportFormat: String { case srt, txt }

    func export(_ r: Library.Recording, as format: ExportFormat) {
        if editor?.recording.url == r.url { editor?.flush() }
        guard let t = transcript(for: r.url) else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(r.title).\(format.rawValue)"
        panel.allowedContentTypes = [UTType(filenameExtension: format.rawValue) ?? .plainText]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try (format == .srt ? t.srt() : t.txt()).write(to: url, atomically: true, encoding: .utf8)
        } catch {
            self.error = "\(error)"
        }
    }

    static let importTypes: [UTType] = [.audio, .movie]

    func importWithPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = Self.importTypes
        panel.message = L("選擇要匯入的音檔或影片，匯入後會自動轉逐字稿", "Choose audio or video files to import. They’ll be transcribed automatically.")
        panel.prompt = L("匯入", "Import")
        guard panel.runModal() == .OK else { return }
        importFiles(panel.urls)
    }

    /// 拖進來的檔案只收聲音和影片；回傳有沒有收
    func canImport(_ urls: [URL]) -> Bool { !importable(urls).isEmpty }

    private func importable(_ urls: [URL]) -> [URL] {
        urls.filter { url in
            guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
            return Self.importTypes.contains { type.conforms(to: $0) }
        }
    }

    @discardableResult
    func importFiles(_ urls: [URL]) -> Bool {
        let ok = importable(urls)
        guard !ok.isEmpty else { return false }
        awaitingNewFrom = Set(library.recordings.map(\.url))
        library.importFiles(ok)
        return true
    }
}

/// AVPlayer 包一層。播放時間放在另一個 ObservableObject，每 0.1 秒更新只會重畫播放列
@MainActor
final class DashboardPlayer: ObservableObject {
    final class Clock: ObservableObject {
        @Published var time: Double = 0
    }

    let clock = Clock()
    @Published private(set) var url: URL?
    @Published private(set) var isPlaying = false
    @Published private(set) var duration: Double = 0
    @Published var rate: Float = 1 {
        didSet {
            // defaultRate：暫停中改速度不會開始播放
            player.defaultRate = rate
            if isPlaying { player.rate = rate }
        }
    }

    private let player = AVPlayer()
    private var observer: Any?
    private var bag = Set<AnyCancellable>()

    init() {
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 10), queue: .main) { [weak self] t in
            MainActor.assumeIsolated {
                guard let self, self.player.currentItem != nil, t.isNumeric else { return }
                self.clock.time = t.seconds
            }
        }
        player.publisher(for: \.timeControlStatus).receive(on: RunLoop.main).sink { [weak self] s in
            self?.isPlaying = s != .paused
        }.store(in: &bag)
    }

    func load(_ url: URL, duration: Double) {
        guard url != self.url else { return }
        player.pause()
        player.replaceCurrentItem(with: Self.item(url))
        self.url = url
        self.duration = duration
        clock.time = 0
    }

    /// 檔案改名：換成新路徑，位置和播放狀態不變
    func moved(to url: URL) {
        let t = clock.time, playing = isPlaying
        player.replaceCurrentItem(with: Self.item(url))
        self.url = url
        seek(t)
        if playing { play() }
    }

    func unload() {
        player.pause()
        player.replaceCurrentItem(with: nil)
        url = nil
        duration = 0
        clock.time = 0
    }

    func play() {
        // 播完了再按播放就從頭來
        if clock.time >= duration - 0.3 { seek(0) }
        player.playImmediately(atRate: rate)
    }

    func pause() { player.pause() }
    func toggle() { isPlaying ? pause() : play() }

    func seek(_ t: Double) {
        let t = min(max(t, 0), duration)
        clock.time = t
        player.seek(to: CMTime(seconds: t, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func skip(_ by: Double) { seek(clock.time + by) }
}

extension Library.Recording {
    // 每列每次重畫都會用到，formatter 建一次就好
    private static let thisYear = formatter("M月d日 HH:mm")
    private static let otherYear = formatter("yyyy年M月d日 HH:mm")
    private static let thisYearEN = formatter("MMM d, HH:mm", locale: "en_US")
    private static let otherYearEN = formatter("MMM d, yyyy, HH:mm", locale: "en_US")
    private static func formatter(_ format: String, locale: String = "zh_Hant_TW") -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: locale)
        f.dateFormat = format
        return f
    }

    var dateText: String {
        let sameYear = Calendar.current.isDate(date, equalTo: Date(), toGranularity: .year)
        let f = Settings.english ? (sameYear ? Self.thisYearEN : Self.otherYearEN) : (sameYear ? Self.thisYear : Self.otherYear)
        return f.string(from: date)
    }
}


extension DashboardPlayer {
    /// MeetRec 的錄音左＝我、右＝對方，戴耳機聽會一邊一個人；播放時把兩聲道混在一起兩邊都放（檔案不動）。
    /// 乘 0.707（等功率）：只在一邊的人聲只小 3 dB；兩邊相同的一般立體聲大 3 dB 也還不會破音
    nonisolated static func item(_ url: URL) -> AVPlayerItem {
        let item = AVPlayerItem(url: url)
        Task { @MainActor in
            guard let track = try? await item.asset.loadTracks(withMediaType: .audio).first, let tap = mixdownTap() else { return }
            let params = AVMutableAudioMixInputParameters(track: track)
            params.audioTapProcessor = tap
            let mix = AVMutableAudioMix()
            mix.inputParameters = [params]
            item.audioMix = mix
        }
        return item
    }

    nonisolated static func mixdownTap() -> MTAudioProcessingTap? {
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0, clientInfo: nil,
            init: nil, finalize: nil, prepare: nil, unprepare: nil,
            process: { tap, frames, _, buffers, framesOut, flagsOut in
                guard MTAudioProcessingTapGetSourceAudio(tap, frames, buffers, flagsOut, nil, framesOut) == noErr else { return }
                let list = UnsafeMutableAudioBufferListPointer(buffers)
                let n = Int(framesOut.pointee)
                if list.count >= 2, let l = list[0].mData?.assumingMemoryBound(to: Float.self), let r = list[1].mData?.assumingMemoryBound(to: Float.self) {
                    for i in 0..<n {
                        let m = (l[i] + r[i]) * 0.707
                        l[i] = m
                        r[i] = m
                    }
                } else if list.count == 1, list[0].mNumberChannels == 2, let p = list[0].mData?.assumingMemoryBound(to: Float.self) {
                    for i in 0..<n {
                        let m = (p[2 * i] + p[2 * i + 1]) * 0.707
                        p[2 * i] = m
                        p[2 * i + 1] = m
                    }
                }
            })
        var tap: MTAudioProcessingTap?
        guard MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks, kMTAudioProcessingTapCreationFlag_PreEffects, &tap) == noErr else { return nil }
        return tap
    }
}
