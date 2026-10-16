import AppKit
import AVFoundation
import AVKit
import SwiftUI

struct DashboardView: View {
    @ObservedObject var model: DashboardModel
    @State private var renameText = ""
    @AppStorage("language") private var language = Settings.Language.system

    var body: some View {
        NavigationSplitView {
            SidebarView(model: model)
                .navigationSplitViewColumnWidth(min: 220, ideal: 270, max: 400)
        } detail: {
            // 不用 .inspector：它打開時會把整個視窗撐寬，這裡要的是從中間這欄切出空間
            HSplitView {
                DetailView(model: model)
                    .frame(minWidth: 360, maxWidth: .infinity)
                if model.chatOpen {
                    AssistantPanel(model: model)
                        .frame(minWidth: 280, idealWidth: 340, maxWidth: 560)
                }
            }
        }
        .id(language)
        .navigationTitle("MeetRec")
        .toolbar {
            // 錄音放最前面、自成一顆，不跟重新轉錄那些混在一起
            ToolbarItem(placement: .navigation) { RecordButton() }
            ToolbarItem(placement: .navigation) {
                // 圖示旁邊放 YouTube、Podcast、Spotify 的 logo，一看就知道網址也能匯入
                Button { model.importing = true } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "square.and.arrow.down")
                        ForEach(LinkSource.allCases, id: \.self) { s in
                            LogoMark(name: "\(s)", color: s.color, size: 13)
                        }
                    }
                    .padding(.horizontal, 4)
                }
                    .help(L("匯入音檔、影片，或 YouTube、Podcast、Spotify 網址", "Import audio, video, or a YouTube, podcast or Spotify link"))
            }
            // 放在最外層、一直都在：切換錄音時工具列不用重建
            ToolbarItemGroup(placement: .primaryAction) {
                let r = model.selectedRecording
                let has = r.map(model.hasTranscript) ?? false
                let busy = r.map { model.status[$0.url].map { if case .failed = $0 { false } else { true } } ?? false } ?? false
                Button { model.retranscribing = r } label: { Label(L("重新轉錄", "Re-transcribe"), systemImage: "arrow.clockwise") }
                    .help(L("重新轉逐字稿（會蓋掉手動修改）", "Re-transcribe (overwrites manual edits)"))
                    .disabled(!has || busy)
                Menu {
                    ForEach(DashboardModel.ExportFormat.allCases, id: \.self) { f in
                        Button(f.label + "…") { if let r { model.export(r, as: f) } }
                    }
                } label: { Label(L("匯出", "Export"), systemImage: "square.and.arrow.up") }
                    .help(L("匯出逐字稿", "Export transcript"))
                    .disabled(!has)
                Button { if let r { model.reveal(r) } } label: { Label(L("在 Finder 中顯示", "Show in Finder"), systemImage: "folder") }
                    .help(L("在 Finder 中顯示", "Show in Finder"))
                    .disabled(r == nil)
                Button { model.toggleChat() } label: { Label { Text(L("AI 對話", "AI Chat")) } icon: { AssistantMarks(kinds: model.assistantKinds) } }
                    .help(L("和 AI 討論這場會議（⌘E）", "Discuss this meeting with AI (⌘E)"))
            }
        }
        .overlay {
            if model.dropTargeted {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [8, 6]))
                    .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                    .overlay { Label(L("放開就匯入並轉逐字稿", "Drop to import and transcribe"), systemImage: "square.and.arrow.down").font(.title2.weight(.medium)) }
                    .padding(8)
                    .allowsHitTesting(false)
            }
        }
        .alert(L("重新命名", "Rename"), isPresented: present($model.renaming)) {
            TextField(L("名稱", "Name"), text: $renameText)
            Button(L("取消", "Cancel"), role: .cancel) {}
            Button(L("好", "OK")) { if let r = model.renaming { model.rename(r, to: renameText) } }
        }
        .onChange(of: model.renaming) { _, r in if let r { renameText = r.name } }
        .alert(L("新增資料夾", "New Folder"), isPresented: $model.creatingGroup) {
            TextField(L("名稱", "Name"), text: $renameText)
            Button(L("取消", "Cancel"), role: .cancel) {}
            Button(L("好", "OK")) { model.createGroup(renameText) }
        }
        .onChange(of: model.creatingGroup) { _, on in if on { renameText = "" } }
        .alert(L("重新命名資料夾", "Rename Folder"), isPresented: present($model.renamingGroup)) {
            TextField(L("名稱", "Name"), text: $renameText)
            Button(L("取消", "Cancel"), role: .cancel) {}
            Button(L("好", "OK")) { if let g = model.renamingGroup { model.renameGroup(g, to: renameText) } }
        }
        .onChange(of: model.renamingGroup) { _, g in if let g { renameText = g } }
        .alert(L("要把資料夾「\(model.deletingGroup ?? "")」移到垃圾桶嗎？", "Move the folder “\(model.deletingGroup ?? "")” to the Trash?"), isPresented: present($model.deletingGroup)) {
            Button(L("取消", "Cancel"), role: .cancel) {}
            Button(L("移到垃圾桶", "Move to Trash"), role: .destructive) { if let g = model.deletingGroup { model.deleteGroup(g) } }
        } message: {
            Text(L("裡面的錄音會一起移到垃圾桶。只想拆掉資料夾的話，先把錄音拖出來。", "The recordings inside will be moved to the Trash too. To keep them, drag them out first."))
        }
        .alert(L("要把「\(model.deleting?.name ?? "")」移到垃圾桶嗎？", "Move “\(model.deleting?.name ?? "")” to the Trash?"), isPresented: present($model.deleting)) {
            Button(L("取消", "Cancel"), role: .cancel) {}
            Button(L("移到垃圾桶", "Move to Trash"), role: .destructive) { if let r = model.deleting { model.delete(r) } }
        } message: {
            Text(L("整個資料夾（音檔、逐字稿、SRT、TXT）會一起移到垃圾桶。", "The whole folder (audio, transcript, SRT, TXT) will be moved to the Trash."))
        }
        .alert(L("要重新轉逐字稿嗎？", "Re-transcribe this recording?"), isPresented: present($model.retranscribing)) {
            Button(L("取消", "Cancel"), role: .cancel) {}
            // 這次用哪個轉，不改設定：已下載的本機模型各一個，設好 key 的雲端服務一個
            ForEach(Models.speech.filter(Models.installed)) { m in
                Button(L("本機：\(m.name)", "On This Mac: \(m.name)") + (!Settings.cloudTranscription && m.id == Models.current.id ? L("（目前設定）", " (Current)") : "")) {
                    if let r = model.retranscribing { model.transcribe(r, engine: .local(m)) }
                }
            }
            let service = Settings.transcriptionService
            if service.apiKey != nil {
                Button(L("☁︎ 雲端：\(service.name)", "☁︎ Cloud: \(service.name)") + (Settings.cloudTranscription ? L("（目前設定）", " (Current)") : "")) {
                    if let r = model.retranscribing { model.transcribe(r, engine: .cloud(service, model: Settings.transcriptionModel)) }
                }
            }
        } message: {
            let anyLocal = Models.speech.contains(where: Models.installed)
            Text(L("新的逐字稿會蓋掉現在的版本，包括手動改過的文字和說話者名稱。選雲端會把錄音上傳轉文字。", "The new transcript will replace the current one, including any text and speaker names you edited. Cloud uploads the recording to be transcribed. ")
                 + (anyLocal ? L("其他本機模型要先到設定下載。", "Download other on-device models in Settings.") : L("本機模型要先到設定下載。", "Download an on-device model in Settings first.")))
        }
        .sheet(isPresented: $model.importing) {
            ImportSheet(chooseFiles: model.importWithPanel, dropFiles: { model.importFiles($0) }, importLink: model.importLink)
        }
        .alert(L("出了點問題", "Something went wrong"), isPresented: present($model.error)) {
            Button(L("好", "OK")) {}
        } message: {
            Text(model.error ?? "")
        }
    }

    /// 有值就顯示 alert，關掉時清成 nil
    private func present<T>(_ value: Binding<T?>) -> Binding<Bool> {
        Binding(get: { value.wrappedValue != nil }, set: { if !$0 { value.wrappedValue = nil } })
    }
}

// MARK: 側邊欄

private struct SidebarView: View {
    @ObservedObject var model: DashboardModel
    @ObservedObject private var library = Library.shared
    /// 收起來的資料夾
    @State private var collapsed: Set<String> = []
    /// 拖著錄音停在哪個資料夾上；"" 是「錄音」標題（移出資料夾）
    @State private var target: String?

    private func row(_ r: Library.Recording) -> some View {
        RecordingRow(recording: r, status: library.status[r.url], hasTranscript: model.hasTranscript(r), snippet: model.snippet(for: r))
            .tag(DashboardSelection.recording(r.url))
            .contextMenu { RecordingActions(model: model, recording: r) }
            // 拖的是路徑文字不是檔案：檔案的話整個視窗會當成要匯入
            .draggable(r.url.path)
    }

    private func drop(_ paths: [String], into group: String?) -> Bool {
        let moving = library.recordings.filter { paths.contains($0.url.path) }
        moving.forEach { model.move($0, to: group) }
        return !moving.isEmpty
    }

    var body: some View {
        let items = model.visibleRecordings
        List(selection: Binding(get: { model.selection }, set: { model.pick($0) })) {
            if let live = library.live {
                Section(L("錄音中", "Recording")) {
                    LiveRow(live: live).tag(DashboardSelection.live)
                }
            }
            if !model.linkDownloads.isEmpty {
                Section(L("下載中", "Downloading")) {
                    ForEach(model.linkDownloads) { DownloadRow(download: $0) }
                }
            }
            if !model.search.isEmpty {
                // 搜尋時不分資料夾
                if !items.isEmpty {
                    Section(L("搜尋結果", "Search Results")) {
                        ForEach(items, content: row)
                    }
                }
            } else if !items.isEmpty || !library.groups.isEmpty {
                Section {
                    ForEach(library.groups, id: \.self) { g in
                        DisclosureGroup(isExpanded: Binding(get: { !collapsed.contains(g) }, set: { if $0 { collapsed.remove(g) } else { collapsed.insert(g) } })) {
                            ForEach(items.filter { $0.group == g }, content: row)
                        } label: {
                            Label(g, systemImage: "folder")
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 2)
                                .background(target == g ? Color.accentColor.opacity(0.25) : .clear, in: RoundedRectangle(cornerRadius: 4))
                                .dropDestination(for: String.self) { paths, _ in drop(paths, into: g) } isTargeted: { target = $0 ? g : (target == g ? nil : target) }
                                .contextMenu {
                                    Button(L("重新命名…", "Rename…")) { model.renamingGroup = g }
                                    Button(L("在 Finder 中顯示", "Show in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([library.folder.appendingPathComponent(g)]) }
                                    Divider()
                                    Button(L("移到垃圾桶…", "Move to Trash…"), role: .destructive) { model.deletingGroup = g }
                                }
                        }
                    }
                    ForEach(items.filter { $0.group == nil }, content: row)
                } header: {
                    // 拖到這裡＝移出資料夾
                    Text(L("錄音", "Recordings"))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(target == "" ? Color.accentColor.opacity(0.25) : .clear, in: RoundedRectangle(cornerRadius: 4))
                        .dropDestination(for: String.self) { paths, _ in drop(paths, into: nil) } isTargeted: { target = $0 ? "" : (target == "" ? nil : target) }
                }
            }
        }
        // 不用 .searchable：它在 NavigationSplitView 裡會收集每一欄的 preference，每次切換錄音都把整份逐字稿清單排版一遍
        .safeAreaInset(edge: .top) {
            SearchField(text: $model.search, model: model)
                .padding(.horizontal, 10)
                .padding(.bottom, 4)
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button { model.creatingGroup = true } label: { Label(L("新增資料夾", "New Folder"), systemImage: "folder.badge.plus") }
                    .buttonStyle(.borderless)
                    .help(L("新增資料夾，再把錄音拖進去", "New folder — then drag recordings into it"))
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .overlay {
            if library.recordings.isEmpty && library.live == nil {
                ContentUnavailableView {
                    Label(L("還沒有錄音", "No Recordings Yet"), systemImage: "waveform")
                } description: {
                    Text(L("瀏覽器或會議 app 開始用麥克風時 MeetRec 會問要不要錄。也可以把音檔或影片拖進來。", "MeetRec asks whether to record when your browser or a meeting app starts using the microphone. You can also drag audio or video files here."))
                } actions: {
                    Button(L("匯入…", "Import…")) { model.importing = true }
                }
            } else if items.isEmpty && !model.search.isEmpty {
                ContentUnavailableView.search(text: model.search)
            }
        }
    }
}

private struct SearchField: NSViewRepresentable {
    @Binding var text: String
    let model: DashboardModel

    func makeNSView(context: Context) -> NSSearchField {
        let f = NSSearchField()
        f.placeholderString = L("搜尋標題或逐字稿", "Search titles or transcripts")
        f.sendsSearchStringImmediately = true
        f.delegate = context.coordinator
        model.focusSearch = { [weak f] in f?.window?.makeFirstResponder(f) }
        return f
    }

    func updateNSView(_ f: NSSearchField, context: Context) {
        if f.stringValue != text { f.stringValue = text }
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        let text: Binding<String>
        init(text: Binding<String>) { self.text = text }
        func controlTextDidChange(_ note: Notification) {
            if let f = note.object as? NSSearchField { text.wrappedValue = f.stringValue }
        }
    }
}

private struct LiveRow: View {
    let live: Library.Live
    @State private var blink = false

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(live.problem != nil ? Color.orange : live.paused ? Color.secondary : Color.red)
                .frame(width: 9, height: 9)
                .opacity(live.paused || !blink ? 1 : 0.35)
                .animation(live.paused ? nil : .easeInOut(duration: 0.9).repeatForever(), value: blink)
                .onAppear { blink = true }
            VStack(alignment: .leading, spacing: 2) {
                Text(live.title).lineLimit(1)
                Text(live.paused ? L("已暫停 · \(Transcript.clock(live.elapsed))", "Paused · \(Transcript.clock(live.elapsed))") : Transcript.clock(live.elapsed))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
    }
}

private struct DownloadRow: View {
    let download: DashboardModel.LinkDownload

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(download.title ?? download.link).lineLimit(1).truncationMode(.middle).help(download.link)
            HStack(spacing: 4) {
                if let p = download.progress {
                    ProgressView(value: p).frame(width: 36).controlSize(.mini)
                    Text(L("下載中 \(Int(p * 100))%", "Downloading \(Int(p * 100))%"))
                } else {
                    ProgressView().controlSize(.mini)
                    Text(L("準備中", "Preparing"))
                }
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 3)
    }
}

private struct RecordingRow: View {
    let recording: Library.Recording
    let status: Library.Status?
    let hasTranscript: Bool
    let snippet: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(recording.name).lineLimit(1).truncationMode(.middle).help(recording.name)
            HStack(spacing: 6) {
                Text(recording.dateText)
                Text(Transcript.clock(recording.duration))
                Spacer(minLength: 0)
                statusView
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            if let s = snippet {
                Text(s).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .padding(.vertical, 3)
    }

    /// 剩下的時間，進位到分鐘：估計本來就不準，秒數只會一直跳
    static func left(_ seconds: TimeInterval) -> String {
        seconds < 60 ? L("剩不到 1 分鐘", "under a minute left") : L("約剩 \(Int((seconds / 60).rounded(.up))) 分鐘", "about \(Int((seconds / 60).rounded(.up))) min left")
    }

    @ViewBuilder private var statusView: some View {
        switch status {
        case .transcribing(0, _):
            HStack(spacing: 4) {
                ProgressView().controlSize(.mini)
                Text(L("準備轉錄", "Preparing"))
            }
        case .transcribing(let p, let remaining):
            HStack(spacing: 4) {
                ProgressView(value: p).frame(width: 36).controlSize(.mini)
                Text(L("轉錄中 \(Int(p * 100))%", "Transcribing \(Int(p * 100))%") + (remaining.map { " · " + Self.left($0) } ?? ""))
            }
        case .queued:
            Text(L("排隊中", "Queued"))
        case .failed:
            Label(L("失敗", "Failed"), systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
        case nil:
            if !hasTranscript { Text(L("尚未轉錄", "Not transcribed")).foregroundStyle(.tertiary) }
        }
    }
}

/// 右鍵選單和工具列共用的動作
private struct RecordingActions: View {
    let model: DashboardModel
    let recording: Library.Recording

    var body: some View {
        let busy = Library.shared.status[recording.url].map { if case .failed = $0 { false } else { true } } ?? false
        let has = model.hasTranscript(recording)
        Button(L("重新命名…", "Rename…")) { model.renaming = recording }
        Button(L("在 Finder 中顯示", "Show in Finder")) { model.reveal(recording) }
        let groups = Library.shared.groups.filter { $0 != recording.group }
        if !groups.isEmpty || recording.group != nil {
            Menu(L("移到", "Move To")) {
                ForEach(groups, id: \.self) { g in Button(g) { model.move(recording, to: g) } }
                if recording.group != nil {
                    if !groups.isEmpty { Divider() }
                    Button(L("移出資料夾", "Out of Folder")) { model.move(recording, to: nil) }
                }
            }
        }
        Divider()
        Button(has ? L("重新轉逐字稿…", "Re-transcribe…") : L("轉逐字稿", "Transcribe")) {
            if has { model.retranscribing = recording } else { model.transcribe(recording) }
        }
        .disabled(busy)
        Menu(L("匯出", "Export")) {
            ForEach(DashboardModel.ExportFormat.allCases, id: \.self) { f in
                Button(f.label + "…") { model.export(recording, as: f) }
            }
        }.disabled(!has)
        Divider()
        Button(L("移到垃圾桶…", "Move to Trash…"), role: .destructive) { model.deleting = recording }
            .keyboardShortcut(.delete, modifiers: .command)
    }
}

// MARK: 右邊

/// 不觀察 Library：錄音中每秒更新的 live 只讓 LiveDetail 重畫
private struct DetailView: View {
    @ObservedObject var model: DashboardModel

    var body: some View {
        switch model.shown {
        case .live:
            LiveDetail()
        case .recording:
            if let r = model.selectedRecording {
                // 不用 .id：換錄音時沿用同一組畫面，只換內容
                RecordingDetail(model: model, recording: r, status: model.status[r.url])
            } else {
                ContentUnavailableView(L("找不到這場錄音", "Recording Not Found"), systemImage: "questionmark.folder", description: Text(L("檔案可能被移走或刪掉了。", "The files may have been moved or deleted.")))
            }
        case nil:
            ContentUnavailableView(L("選一場錄音", "Select a Recording"), systemImage: "waveform", description: Text(L("在左邊選一場錄音來播放、看逐字稿。", "Choose a recording on the left to play it and read the transcript.")))
        }
    }
}

private struct LiveDetail: View {
    @ObservedObject private var library = Library.shared

    var body: some View {
        if let live = library.live {
            content(live)
        } else {
            ProgressView(L("正在存檔…", "Saving…"))
        }
    }

    private func content(_ live: Library.Live) -> some View {
        VStack(spacing: 18) {
            Label(live.paused ? L("已暫停", "Paused") : L("錄音中", "Recording"), systemImage: live.paused ? "pause.circle.fill" : "record.circle")
                .font(.headline)
                .foregroundStyle(live.paused ? Color.secondary : Color.red)
            Text(live.title).font(.title2).foregroundStyle(.secondary)
            Text(Transcript.clock(live.elapsed))
                .font(.system(size: 72, weight: .light).monospacedDigit())
                .contentTransition(.numericText())
            if let problem = live.problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
            HStack(spacing: 12) {
                Button { Library.shared.toggleLivePause() } label: {
                    Label(live.paused ? L("繼續", "Resume") : L("暫停", "Pause"), systemImage: live.paused ? "play.fill" : "pause.fill").frame(minWidth: 90)
                }
                Button { Library.shared.stopLive() } label: {
                    Label(L("停止並存檔", "Stop and Save"), systemImage: "stop.fill").frame(minWidth: 110)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
            }
            .controlSize(.large)
            Text(L("存檔後會自動轉逐字稿", "The recording will be transcribed automatically after saving")).font(.callout).foregroundStyle(.tertiary)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct RecordingDetail: View {
    @ObservedObject var model: DashboardModel
    /// 模型下載完，「還沒有逐字稿」的提示要跟著換
    @ObservedObject private var models = Models.shared
    let recording: Library.Recording
    let status: Library.Status?
    @State private var title = ""
    /// title 是哪一場的標題：換錄音時欄位還沒失焦，不能把舊的字套到新的錄音上
    @State private var titleURL: URL?
    @FocusState private var editingTitle: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            VideoSlot(player: model.player, url: recording.url, editor: model.editor.flatMap { $0.recording.url == recording.url ? $0 : nil })
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            PlayerBar(player: model.player, clock: model.player.clock,
                      editor: model.editor.flatMap { $0.recording.url == recording.url ? $0 : nil })
        }
    }

    private var busy: Bool {
        switch status {
        case .queued, .transcribing: true
        default: false
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField(L("標題", "Title"), text: $title)
                .textFieldStyle(.plain)
                .font(.title2.weight(.semibold))
                .focused($editingTitle)
                .onSubmit { commitTitle() }
                .onExitCommand { title = recording.name; editingTitle = false }
                .onChange(of: editingTitle) { _, editing in if !editing { commitTitle() } }
                .help(L("點一下改名", "Click to rename"))
            HStack(spacing: 8) {
                Label(recording.dateText, systemImage: "calendar")
                Label(Transcript.clock(recording.duration), systemImage: "clock")
                if let n = model.editor?.transcript.speakerOrder.count, n > 1 {
                    Label(L("\(n) 位說話者", "\(n) speakers"), systemImage: "person.2")
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { title = recording.name; titleURL = recording.url }
        .onChange(of: recording.url) { old, _ in
            // 改到一半就切到別場：改名還是套用到原本那一場
            let t = title.trimmingCharacters(in: .whitespaces)
            if titleURL == old, let r = model.library.recordings.first(where: { $0.url == old }), !t.isEmpty, t != r.name {
                model.rename(r, to: t)
            }
            title = recording.name
            titleURL = recording.url
        }
    }

    private func commitTitle() {
        guard titleURL == recording.url else { return }
        let t = title.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, t != recording.name else {
            title = recording.name
            return
        }
        model.rename(recording, to: t)
        // 失敗的話（例如名稱重複）改回原來的
        if model.error != nil { title = recording.name }
    }

    @ViewBuilder private var content: some View {
        let editor = model.editor.flatMap { $0.recording.url == recording.url ? $0 : nil }
        VStack(spacing: 0) {
            switch status {
            case .queued, .transcribing:
                if editor != nil { progressBanner.padding(12) }
            case .failed(let message):
                if editor != nil { failedBanner(message).padding(12) }
            case nil:
                EmptyView()
            }
            if let editor {
                // 換錄音就換一個新的清單（捲動位置回到最上面、編輯狀態清掉）
                // disabled 是環境值，傳不進另一個 NSHostingView，要套在裡面
                Isolated(content: TranscriptView(editor: editor, player: model.player).disabled(busy).allowsHitTesting(!busy).id(editor.recording.url))
                    .opacity(busy ? 0.45 : 1)
            } else {
                switch status {
                case .queued, .transcribing:
                    VStack(spacing: 12) {
                        Image(systemName: "waveform.badge.magnifyingglass").font(.system(size: 40)).foregroundStyle(.secondary)
                        progressBanner.frame(maxWidth: 320)
                    }
                    .frame(maxHeight: .infinity)
                case .failed(let message):
                    ContentUnavailableView {
                        Label(L("轉逐字稿失敗", "Transcription Failed"), systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(message)
                    } actions: {
                        Button(L("重試", "Retry")) { model.transcribe(recording) }
                        if !Models.ready { Button(L("打開設定", "Open Settings")) { SettingsWindow.shared.show() } }
                    }
                case nil:
                    let _ = models.revision
                    ContentUnavailableView {
                        Label(L("還沒有逐字稿", "No Transcript Yet"), systemImage: "text.bubble")
                    } description: {
                        if Models.ready {
                            Text(L("轉好之後可以點時間跳著聽、修正文字和說話者。", "Once transcribed, you can click timestamps to jump around and fix text and speakers."))
                        } else {
                            Text(L("要先下載語音模型才能轉逐字稿，只需要下載一次。", "Download the speech models first. You only need to do this once."))
                        }
                    } actions: {
                        if Models.ready {
                            Button(L("開始轉逐字稿", "Transcribe")) { model.transcribe(recording) }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.large)
                        } else {
                            // 直接開始下載，設定頁顯示進度
                            Button(L("下載語音模型", "Download Speech Models")) {
                                models.downloadMissing()
                                SettingsWindow.shared.show()
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder private var progressBanner: some View {
        if case .transcribing(0, _) = status {
            VStack(alignment: .leading, spacing: 6) {
                Text(L("準備轉錄：解碼音檔、找出說話的段落", "Preparing: decoding audio and finding speech")).font(.callout)
                ProgressView().progressViewStyle(.linear)
            }
        } else if case .transcribing(let p, let remaining) = status {
            VStack(alignment: .leading, spacing: 6) {
                Text(L("正在轉逐字稿… \(Int(p * 100))%", "Transcribing… \(Int(p * 100))%") + (remaining.map { " · " + RecordingRow.left($0) } ?? ""))
                    .font(.callout.monospacedDigit())
                ProgressView(value: p)
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text(L("排隊中，等前面的轉完", "Queued, waiting for earlier recordings to finish")).font(.callout)
                ProgressView().progressViewStyle(.linear)
            }
        }
    }

    private func failedBanner(_ message: String) -> some View {
        HStack {
            Label(L("重新轉錄失敗：\(message)", "Re-transcription failed: \(message)"), systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
            Spacer()
            if !Models.ready { Button(L("打開設定", "Open Settings")) { SettingsWindow.shared.show() } }
            Button(L("重試", "Retry")) { model.transcribe(recording) }
        }
    }
}

/// 包一層自己的 NSHostingView：NavigationSplitView 每次更新都會往下收集 preference，
/// 穿過長逐字稿的 LazyVStack 時會逼它把一大堆列重新排版（實測一次切換 20–30 ms）。隔開之後只有逐字稿自己變動時才排版
private struct Isolated<Content: View>: NSViewRepresentable {
    let content: Content

    func makeNSView(context: Context) -> NSHostingView<Content> {
        let v = NSHostingView(rootView: content)
        v.sizingOptions = []
        return v
    }

    func updateNSView(_ v: NSHostingView<Content>, context: Context) {
        v.rootView = content
    }
}

private struct PlayerBar: View {
    @ObservedObject var player: DashboardPlayer
    @ObservedObject var clock: DashboardPlayer.Clock
    /// 有逐字稿才有：進度條照說話的人上色
    let editor: TranscriptEditor?
    /// 拖曳中的位置；放開才 seek，拖的時候不被播放時間蓋掉
    @State private var dragging: Double?

    var body: some View {
        HStack(spacing: 14) {
            Button { player.skip(-15) } label: { Image(systemName: "gobackward.15") }
                .help(L("倒退 15 秒", "Back 15 seconds"))
            Button { player.toggle() } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.title2)
                    .frame(width: 26)
            }
            .help(player.isPlaying ? L("暫停（空白鍵）", "Pause (Space)") : L("播放（空白鍵）", "Play (Space)"))
            Button { player.skip(15) } label: { Image(systemName: "goforward.15") }
                .help(L("快轉 15 秒", "Forward 15 seconds"))
            Text(Transcript.clock(dragging ?? clock.time))
                .monospacedDigit()
                .frame(minWidth: 44, alignment: .trailing)
            SpeakerTrack(editor: editor, time: dragging ?? clock.time, duration: player.duration) { t, done in
                if done {
                    player.seek(t)
                    dragging = nil
                } else {
                    dragging = t
                }
            }
            Text(Transcript.clock(player.duration))
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Picker(L("速度", "Speed"), selection: $player.rate) {
                ForEach([Float(1), 1.25, 1.5, 2], id: \.self) { r in
                    Text(r == 1 ? "1x" : r == 2 ? "2x" : "\(r, specifier: "%g")x").tag(r)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
            .help(L("播放速度", "Playback speed"))
        }
        .font(.body)
        .buttonStyle(.borderless)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .disabled(player.url == nil)
        .background(.bar)
    }
}

/// 播放進度條：每一段照當時說話的人上色，播過的實色、還沒播的淡色，沒人說話的地方灰色。點或拖曳跳到那裡
private struct SpeakerTrack: View {
    /// nil＝沒有逐字稿，整條用強調色
    let editor: TranscriptEditor?
    let time: Double
    let duration: Double
    /// (時間, 放開了沒)
    let seek: (Double, Bool) -> Void

    var body: some View {
        if let editor {
            Colored(editor: editor, time: time, duration: duration, seek: seek)
        } else {
            Bar(spans: nil, time: time, duration: duration, seek: seek)
        }
    }

    /// 改說話者顏色時要重畫，所以另外包一層盯著 editor
    private struct Colored: View {
        @ObservedObject var editor: TranscriptEditor
        let time: Double
        let duration: Double
        let seek: (Double, Bool) -> Void

        var body: some View {
            Bar(spans: editor.transcript.segments.map { ($0.start, $0.end, editor.color($0.speaker)) }, time: time, duration: duration, seek: seek)
        }
    }

    private struct Bar: View {
        let spans: [(start: Double, end: Double, color: Color)]?
        let time: Double
        let duration: Double
        let seek: (Double, Bool) -> Void

        var body: some View {
            GeometryReader { geo in
                let w = geo.size.width, d = max(duration, 0.1)
                let x = min(max(time / d, 0), 1) * w
                ZStack(alignment: .leading) {
                    Canvas { ctx, size in
                        let bar = CGRect(x: 0, y: (size.height - 6) / 2, width: size.width, height: 6)
                        let played = CGRect(x: 0, y: bar.minY, width: x, height: bar.height)
                        ctx.clip(to: Path(roundedRect: bar, cornerRadius: 3))
                        ctx.fill(Path(bar), with: .color(.secondary.opacity(0.25)))
                        guard let spans else { return ctx.fill(Path(played), with: .color(.accentColor)) }
                        for s in spans where s.end > s.start {
                            ctx.fill(Path(CGRect(x: s.start / d * size.width, y: bar.minY, width: max((s.end - s.start) / d * size.width, 1), height: bar.height)),
                                     with: .color(s.color))
                        }
                        // 還沒播的蓋一層底色變淡；不直接畫半透明色，兩個人同時說話的地方才不會混成別的顏色
                        ctx.fill(Path(CGRect(x: x, y: bar.minY, width: size.width - x, height: bar.height)),
                                 with: .color(Color(nsColor: .windowBackgroundColor).opacity(0.6)))
                    }
                    Circle()
                        .fill(.white)
                        .shadow(color: .black.opacity(0.3), radius: 1.5, y: 0.5)
                        .frame(width: 12, height: 12)
                        .offset(x: x - 6)
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { seek(min(max($0.location.x / w, 0), 1) * d, false) }
                    .onEnded { seek(min(max($0.location.x / w, 0), 1) * d, true) })
            }
            .frame(height: 16)
        }
    }
}

// MARK: AI 對話

private struct AssistantPanel: View {
    @ObservedObject var model: DashboardModel
    @AppStorage("assistant") private var preferred = AssistantKind.claude
    /// 各工具選的模型，空字串＝工具自己的預設
    @AppStorage("assistantModel.claude") private var claudeModel = ""
    @AppStorage("assistantModel.codex") private var codexModel = ""

    var body: some View {
        // 撐滿整個高度：提示畫面（例如這場還沒有逐字稿）只有內容那麼高的話，分隔線會只畫到一半
        panel.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder private var panel: some View {
        let kinds = model.assistantKinds
        if model.assistants == nil {
            ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if kinds.isEmpty {
            ContentUnavailableView {
                Label(L("需要先安裝 Claude Code 或 Codex", "Install Claude Code or Codex First"), systemImage: "bubble.left.and.text.bubble.right")
            } description: {
                Text(L("MeetRec 用你電腦上的 AI 工具讀逐字稿，登入的是你自己的帳號。", "MeetRec reads transcripts with the AI tool on your Mac, signed in with your own account."))
            } actions: {
                Link(L("安裝 Claude Code", "Install Claude Code"), destination: URL(string: "https://code.claude.com/docs/en/setup")!)
                Link(L("安裝 Codex", "Install Codex"), destination: URL(string: "https://developers.openai.com/codex/cli")!)
            }
        } else if let r = model.selectedRecording, model.editor?.recording.url == r.url, let kind = kinds.contains(preferred) ? preferred : kinds.first {
            let chat = model.chat(for: r, kind: kind)
            let modelID = kind == .claude ? $claudeModel : $codexModel
            AssistantChatView(chat: chat, kinds: kinds, kind: $preferred, modelID: modelID,
                              others: model.library.recordings.filter { $0.url != r.url && model.hasTranscript($0) },
                              send: { model.ask($0, images: $1, refs: $2, in: chat, about: r, model: modelID.wrappedValue.isEmpty ? nil : modelID.wrappedValue) },
                              reset: { model.resetChat(for: r, kind: kind) },
                              cleanup: model.cleanup.flatMap { $0.editor === model.editor ? $0 : nil },
                              startCleanup: { model.startCleanup(kind: kind, model: modelID.wrappedValue.isEmpty ? nil : modelID.wrappedValue, instruction: $0) },
                              endCleanup: model.endCleanup,
                              seek: model.player.seek)
                .id(ObjectIdentifier(chat))
        } else {
            ContentUnavailableView(L("選一場有逐字稿的錄音", "Select a Transcribed Recording"), systemImage: "bubble.left.and.text.bubble.right")
        }
    }
}

private struct AssistantChatView: View {
    @ObservedObject var chat: AssistantChat
    let kinds: [AssistantKind]
    @Binding var kind: AssistantKind
    @Binding var modelID: String
    /// 可以用 @ 引用的其他場（有逐字稿的）
    let others: [Library.Recording]
    let send: (String, [Data], [Library.Recording]) -> Void
    let reset: () -> Void
    let cleanup: TranscriptCleanup?
    /// nil＝預設的整理；AI 對話回覆裡給的指示就照那句改
    let startCleanup: (String?) -> Void
    let endCleanup: () -> Void
    let seek: (Double) -> Void
    @State private var draft = ""
    /// 還沒送出的圖
    @State private var images: [Data] = []
    /// 用 @ 引用、還沒送出的其他場
    @State private var refs: [Library.Recording] = []
    /// @ 選單裡反白的那一個
    @State private var pick = 0
    @State private var dropping = false
    @State private var pasteMonitor: Any?
    /// 剛複製的那則回覆，按鈕短暫變成打勾
    @State private var copied: UUID?
    @FocusState private var focused: Bool

    var body: some View {
        let models = chat.kind.models
        VStack(spacing: 0) {
            HStack {
                Menu {
                    if kinds.count > 1 {
                        Picker(L("工具", "Tool"), selection: $kind) {
                            ForEach(kinds) { Text($0.name).tag($0) }
                        }
                        .pickerStyle(.inline)
                    }
                    Picker(L("模型", "Model"), selection: $modelID) {
                        Text(L("預設", "Default")).tag("")
                        ForEach(models, id: \.id) { Text($0.name).tag($0.id) }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Text(chat.kind.name + " · " + (models.first { $0.id == modelID }?.name ?? L("預設", "Default")))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                Spacer()
                // 報告類型隨時可選，對話開始後也在
                if chat.kind == .claude {
                    Menu {
                        ForEach(presets, id: \.title) { p in
                            Button { send(p.prompt, [], []) } label: { Label(p.title, systemImage: p.icon) }
                        }
                    } label: {
                        Label(L("報告", "Report"), systemImage: "doc.richtext")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .disabled(chat.running)
                    .help(L("產生報告", "Create a Report"))
                }
                Button { startCleanup(nil) } label: { Label(L("整理", "Clean Up"), systemImage: "wand.and.sparkles").labelStyle(.titleAndIcon).contentShape(Rectangle()) }
                    // 無邊框按鈕在視窗沒被選中時會變灰，看起來像不能按；跟旁邊的「報告」一樣保持黑字
                    .buttonStyle(.plain)
                    .onHover { inside in if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() } }
                    .fixedSize()
                    .help(L("AI 整理逐字稿：修錯字、標點、贅字，看過再套用", "Clean Up Transcript with AI: fix typos, punctuation and filler words, review before applying"))
                    .disabled(chat.running || cleanup != nil)
                Button(action: reset) { Image(systemName: "square.and.pencil") }
                    .buttonStyle(.borderless)
                    .help(L("新對話", "New Chat"))
                    .disabled(chat.messages.isEmpty)
            }
            .padding(.horizontal, 14)
            .frame(height: 40)
            Divider()
            if let cleanup {
                CleanupView(cleanup: cleanup, seek: seek, close: endCleanup)
            } else {
                chatBody
            }
        }
        .overlay {
            if dropping {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
                    .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .padding(4)
                    .allowsHitTesting(false)
            }
        }
        .onDrop(of: [.fileURL, .image], isTargeted: $dropping, perform: drop)
        .onAppear {
            focused = true
            // 文字框自己會吃掉 ⌘V，只會貼文字；剪貼簿是圖的話先攔下來當附件
            pasteMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                guard focused, event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                      event.charactersIgnoringModifiers == "v" else { return event }
                let pasted = pastedImages()
                guard !pasted.isEmpty else { return event }
                images += pasted
                return nil
            }
        }
        .onDisappear {
            if let pasteMonitor { NSEvent.removeMonitor(pasteMonitor) }
            pasteMonitor = nil
        }
    }

    @ViewBuilder private var chatBody: some View {
            let reports = chat.reports
            if !reports.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(reports, id: \.self) { url in
                            // 檔名後面的時間戳不顯示，滑過去看完整檔名
                            let name = url.deletingPathExtension().lastPathComponent
                            Button { DiagramWindow.show(url) } label: {
                                Label(name.replacingOccurrences(of: #" \d{4}-\d{2}-\d{2} \d{2}-\d{2}-\d{2}$"#, with: "", options: .regularExpression),
                                      systemImage: "doc.richtext")
                                    .lineLimit(1)
                                    .font(.callout)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(.quaternary, in: Capsule())
                            }
                            .buttonStyle(.plain)
                            .help(name)
                            .exportMenu(url)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                }
                Divider()
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(chat.messages) { message($0).id($0.id) }
                    }
                    .padding(14)
                }
                .onChange(of: chat.messages.last?.text) { _, _ in
                    if let id = chat.messages.last?.id { withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id, anchor: .bottom) } }
                }
            }
            .overlay {
                if chat.messages.isEmpty {
                    ContentUnavailableView {
                        Label(L("問問這場會議", "Ask About This Meeting"), systemImage: "bubble.left.and.text.bubble.right")
                    } actions: {
                        if chat.kind == .claude {
                            LazyVGrid(columns: [GridItem(.fixed(128), spacing: 10), GridItem(.fixed(128))], spacing: 10) {
                                ForEach(presets, id: \.title) { p in
                                    Button { send(p.prompt, [], []) } label: {
                                        VStack(spacing: 10) {
                                            Image(systemName: p.icon).font(.system(size: 24)).foregroundStyle(Color.accentColor)
                                            Text(p.title).font(.callout.weight(.medium)).foregroundStyle(.primary)
                                        }
                                        .frame(width: 128, height: 96)
                                        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                                        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                }
            }
            ForEach(chat.approvals) { approvalCard($0) }
            VStack(alignment: .leading, spacing: 6) {
                let found = matches
                if !found.isEmpty {
                    // 打 @ 跳出來的錄音清單：上下鍵選、Return 或點一下加入
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(found.enumerated()), id: \.element.url) { i, r in
                            Button { choose(r) } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: "doc.text").foregroundStyle(.secondary)
                                    Text(r.name).lineLimit(1)
                                    Spacer(minLength: 8)
                                    Text(r.dateText).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                                .contentShape(Rectangle())
                                .background(i == min(pick, found.count - 1) ? Color.accentColor.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 6))
                            }
                        }
                    }
                    .padding(.top, 4)
                    Divider()
                }
                if !refs.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(refs, id: \.url) { r in
                                HStack(spacing: 4) {
                                    Image(systemName: "doc.text")
                                    Text(r.name).lineLimit(1)
                                    Button { refs.removeAll { $0.url == r.url } } label: { Image(systemName: "xmark.circle.fill") }
                                        .foregroundStyle(.secondary)
                                        .help(L("移除", "Remove"))
                                }
                                .font(.callout)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(.quaternary, in: Capsule())
                                .help(r.dateText)
                            }
                        }
                        .padding(.top, 4)
                    }
                }
                if !images.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(Array(images.enumerated()), id: \.offset) { i, data in
                                Thumbnail(data: data, size: 48)
                                    .overlay(alignment: .topTrailing) {
                                        Button { images.remove(at: i) } label: {
                                            Image(systemName: "xmark.circle.fill").symbolRenderingMode(.palette)
                                                .foregroundStyle(.white, .black.opacity(0.6))
                                        }
                                        .padding(2)
                                        .help(L("移除", "Remove"))
                                    }
                            }
                        }
                        .padding(.top, 4)
                    }
                }
                HStack(alignment: .bottom, spacing: 6) {
                    Button(action: pickImages) { Image(systemName: "photo.badge.plus").font(.system(size: 15)).foregroundStyle(.secondary) }
                        .help(L("加入圖片（也可以直接拖進來）", "Add Images (or drag them in)"))
                        .padding(.bottom, 3)
                    TextField(L("問點什麼…（@ 引用其他場）", "Ask something… (@ to add another meeting)"), text: $draft, axis: .vertical)
                        .textFieldStyle(.plain)
                        .lineLimit(1...8)
                        .writingToolsBehavior(.disabled)
                        .focused($focused)
                        .onSubmit(submit)
                        .onChange(of: mention) { _, _ in pick = 0 }
                        .onKeyPress(.downArrow) { move(1) }
                        .onKeyPress(.upArrow) { move(-1) }
                        .padding(.vertical, 3)
                    if chat.running {
                        Button { chat.stop() } label: { Image(systemName: "stop.circle.fill").font(.system(size: 20)).foregroundStyle(.secondary) }
                            .help(L("停止", "Stop"))
                    } else {
                        let empty = draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && images.isEmpty
                        Button(action: submit) {
                            Image(systemName: "arrow.up.circle.fill").font(.system(size: 20))
                                .foregroundStyle(empty ? AnyShapeStyle(.tertiary) : AnyShapeStyle(Color.accentColor))
                        }
                        .disabled(empty)
                        .help(L("送出（Return）", "Send (Return)"))
                    }
                }
            }
            .buttonStyle(.borderless)
            .padding(.leading, 8)
            .padding(.trailing, 5)
            .padding(.vertical, 5)
            .background(.background, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.separator))
            .padding(12)
    }

    private func submit() {
        // @ 選單開著的時候 Return 是選那一場
        let found = matches
        if !found.isEmpty { return choose(found[min(pick, found.count - 1)]) }
        let q = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty || !images.isEmpty, !chat.running else { return }
        draft = ""
        send(q, images, refs)
        images = []
        refs = []
    }

    /// 游標前正在打的「@關鍵字」；沒在打就是 nil。中文輸入法打出來的是全形 ＠
    private var mention: Substring? { draft.firstMatch(of: #/(?:^|\s)[@＠]([^\s@＠]*)$/#)?.1 }

    private var matches: [Library.Recording] {
        guard let q = mention else { return [] }
        return Array(others.filter { r in !refs.contains { $0.url == r.url } && (q.isEmpty || r.name.localizedStandardContains(q)) }.prefix(6))
    }

    private func choose(_ r: Library.Recording) {
        refs.append(r)
        if let m = draft.firstMatch(of: #/[@＠][^\s@＠]*$/#) { draft.removeSubrange(m.range) }
        pick = 0
        // 點清單選的話焦點會跑掉，拉回來接著打
        focused = true
    }

    private func move(_ d: Int) -> KeyPress.Result {
        let n = matches.count
        guard n > 0 else { return .ignored }
        pick = (min(pick, n - 1) + d + n) % n
        return .handled
    }

    /// Finder 複製的圖檔，或截圖、瀏覽器「複製圖片」的圖片本身；剪貼簿有文字（例如網頁上連字帶圖複製）就照常貼文字
    private func pastedImages() -> [Data] {
        let pb = NSPasteboard.general
        let files = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true,
                                                                       .urlReadingContentsConformToTypes: ["public.image"]]) as? [URL] ?? []
        if !files.isEmpty { return files.compactMap { NSImage(contentsOf: $0).flatMap(AssistantChat.jpeg) } }
        guard pb.string(forType: .string) == nil else { return [] }
        return (pb.readObjects(forClasses: [NSImage.self]) as? [NSImage] ?? []).compactMap(AssistantChat.jpeg)
    }

    private func pickImages() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.image]
        guard panel.runModal() == .OK else { return }
        images += panel.urls.compactMap { NSImage(contentsOf: $0).flatMap(AssistantChat.jpeg) }
    }

    /// Finder 拖來的是檔案，瀏覽器或預覽程式拖來的可能是圖片本身
    private func drop(_ providers: [NSItemProvider]) -> Bool {
        var accepted = false
        for p in providers {
            if p.canLoadObject(ofClass: URL.self) {
                accepted = true
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    guard let url, let data = NSImage(contentsOf: url).flatMap(AssistantChat.jpeg) else { return }
                    DispatchQueue.main.async { images.append(data) }
                }
            } else if p.canLoadObject(ofClass: NSImage.self) {
                accepted = true
                _ = p.loadObject(ofClass: NSImage.self) { image, _ in
                    guard let data = (image as? NSImage).flatMap(AssistantChat.jpeg) else { return }
                    DispatchQueue.main.async { images.append(data) }
                }
            }
        }
        return accepted
    }

    /// 回覆轉成可點的文字：codex 的檔案引用、反引號包住的路徑、裸網址和裸路徑都變成連結，點了用預設 app 打開
    static func linked(_ text: String) -> AttributedString {
        func fileLink(_ path: String, label: String? = nil) -> String {
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            return "[\(label ?? path)](<\(url.absoluteString)>)"
        }
        var s = text
        // :codex-file-citation{path="…" purpose="output"}
        s = s.replacing(#/:codex-file-citation\{[^}]*?path="([^"]+)"[^}]*\}/#) { fileLink(String($0.1)) }
        // Claude Code 常寫成 [檔名](/Users/…)，路徑有空白時 markdown 解析不了，先換成 file:// 網址
        s = s.replacing(#/\[([^\]\n]+)\]\(<?((?:~|\/)[^)>\n]+)>?\)/#) { fileLink(String($0.2), label: String($0.1)) }
        // `~/…` 或 `/Users/…`，路徑可能有空白，反引號是最可靠的邊界
        s = s.replacing(#/`((?:~|\/)[^`\n]*\/[^`\n]*)`/#) { m in
            let p = String(m.1)
            return FileManager.default.fileExists(atPath: (p as NSString).expandingTildeInPath) ? fileLink(p) : String(m.0)
        }
        var out = (try? AttributedString(markdown: hardBreaks(s), options: .init(interpretedSyntax: .full))) ?? AttributedString(s)
        // 剩下的裸網址、裸路徑（不在連結或程式碼裡的才處理）
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        var links: [(offset: Int, count: Int, url: URL)] = []
        for run in out.runs where run.link == nil && run.inlinePresentationIntent?.contains(.code) != true
            && run.presentationIntent?.components.contains(where: { if case .codeBlock = $0.kind { true } else { false } }) != true {
            let piece = String(out[run.range].characters)
            let ns = NSRange(piece.startIndex..., in: piece)
            var found: [(Range<String.Index>, URL)] = []
            for r in detector?.matches(in: piece, range: ns) ?? [] {
                if let url = r.url, url.scheme?.hasPrefix("http") == true, let range = Range(r.range, in: piece) { found.append((range, url)) }
            }
            // 路徑前面要是開頭、空白或標點，避免把網址或分數的一段當路徑
            for m in piece.matches(of: #/(?:^|[\s"'(\[（「：:])(~?\/[^\s`"'<>()\[\]，。、；：「」（）]+)/#) {
                var p = String(m.1)
                while let last = p.last, ".,;:!?".contains(last) { p.removeLast() }
                let full = (p as NSString).expandingTildeInPath
                guard p.dropFirst().contains("/"), FileManager.default.fileExists(atPath: full),
                      !found.contains(where: { $0.0.overlaps(m.range) }) else { continue }
                let lo = m.1.startIndex
                found.append((lo..<piece.index(lo, offsetBy: p.count), URL(fileURLWithPath: full)))
            }
            let base = out.characters.distance(from: out.startIndex, to: run.range.lowerBound)
            for (range, url) in found {
                links.append((base + piece.distance(from: piece.startIndex, to: range.lowerBound), piece.distance(from: range.lowerBound, to: range.upperBound), url))
            }
        }
        for l in links {
            let start = out.characters.index(out.startIndex, offsetBy: l.offset)
            out[start..<out.characters.index(start, offsetBy: l.count)].link = l.url
        }
        return out
    }

    /// markdown 的單一換行會變成空白，但回覆裡的換行是有意的：接著一般文字的行尾補硬換行。
    /// 下一行是清單、標題、表格等區塊開頭，或這行本身是標題、表格、分隔線、程式碼區塊時不補，免得多出反斜線
    private static func hardBreaks(_ text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        let starts = #/^\s*(?:[-*+]\s|\d+[.)]\s|#{1,6}\s|>|\||```|~~~|(?:[-*_=]\s*){3,}$)/#
        let own = #/^\s*(?:#{1,6}\s|\||(?:[-*_=]\s*){3,}$)/#
        var fenced = false
        for i in lines.indices {
            let line = lines[i]
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") { fenced.toggle(); continue }
            guard !fenced, i + 1 < lines.count,
                  !line.trimmingCharacters(in: .whitespaces).isEmpty, !lines[i + 1].trimmingCharacters(in: .whitespaces).isEmpty,
                  line.prefixMatch(of: own) == nil, lines[i + 1].prefixMatch(of: starts) == nil else { continue }
            lines[i] += "\\"
        }
        return lines.joined(separator: "\n")
    }

    /// Claude 要用 MCP 之類的工具前先問
    private func approvalCard(_ a: AssistantChat.Approval) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(L("要允許使用 \(a.tool) 嗎？", "Allow \(a.tool)?"), systemImage: "hand.raised.fill")
                .font(.callout.weight(.medium))
            if !a.detail.isEmpty {
                Text(a.detail).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(4).textSelection(.enabled)
            }
            HStack {
                Spacer()
                Button(L("拒絕", "Deny")) { chat.answer(a, allow: false) }
                Button(L("允許", "Allow")) { chat.answer(a, allow: true) }.buttonStyle(.borderedProminent)
            }
        }
        .padding(10)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.horizontal, 12)
        .padding(.top, 8)
    }

    /// 回覆中的點點，用工具時旁邊寫是哪個；開始吐圖表 HTML 之後寫畫圖中
    private func working(drawing: Bool) -> some View {
        HStack(spacing: 8) {
            TypingDots()
            if drawing {
                Text(L("製作中…", "Creating…")).font(.callout).foregroundStyle(.secondary)
            } else if let a = chat.activity {
                Text(L("使用 \(a)", "Using \(a)")).font(.callout).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }

    /// 預設的報告類型：每種是一份完整文件，圖表配在需要的章節裡。diagram-design 是給 claude 的 plugin，所以只有 Claude 有
    private var presets: [(icon: String, title: String, prompt: String)] {
        [("doc.richtext", L("會議報告", "Meeting Report"),
          L("把這場會議寫成一份會議報告。章節：摘要（三到五句）、討論重點（議題和誰提的，用 dependency 類型畫人物與議題的關係）、決策、待辦（負責人和期限，用 kanban 類型分已決定／待辦／未解決）、還沒解決的問題。",
            "Write this meeting up as a meeting report. Sections: summary (three to five sentences), discussion (topics and who raised them, with a dependency diagram of people and topics), decisions, action items (owners and due dates, with a kanban of decided / to-do / unresolved), open questions.")),
         ("list.bullet.clipboard", L("行動計畫", "Action Plan"),
          L("根據這場會議寫一份行動計畫。章節：目標、工作項目（負責人、期限、相依關係）、時程（有日期就用 gantt 類型，只有先後順序就用 timeline 類型）、誰負責什麼（swimlane 或 org-chart 類型擇一）、風險和要先確認的事。會議裡沒講到的負責人或期限標「未定」，不要編。",
            "Write an action plan from this meeting. Sections: goal, work items (owner, due date, dependencies), schedule (a gantt if there are dates, a timeline if only order), who owns what (swimlane or org chart, pick one), risks and things to confirm first. Mark owners or dates the meeting didn't give as \"TBD\" — don't invent them.")),
         ("arrow.triangle.branch", L("決策備忘", "Decision Memo"),
          L("把這場會議討論的決定寫成決策備忘。章節：要決定什麼、背景、選項比較（表格列優缺點；適合的話用 quadrant 類型擺位置）、各方意見、結論或建議（會議沒定案就寫目前傾向和還缺什麼資訊）、下一步。",
            "Write the decision discussed in this meeting as a decision memo. Sections: the question, background, options compared (a pros/cons table; a quadrant diagram if it fits), who argued what, the conclusion or recommendation (if undecided, the current leaning and what information is missing), next steps.")),
         ("books.vertical", L("主題整理", "Topic Brief"),
          L("把這場會議的內容整理成一份主題筆記，給沒參加的人讀懂。章節：一句話總結、概念架構（用 tree 或 nested 類型）、各主題重點（流程類的內容用 flowchart 類型）、提到的名詞和數字、延伸問題。",
            "Turn this meeting into a topic brief someone who wasn't there can follow. Sections: one-line summary, how the ideas fit together (tree or nested diagram), key points per topic (a flowchart for anything procedural), terms and figures mentioned, follow-up questions."))]
    }

    @ViewBuilder private func message(_ m: AssistantChat.Message) -> some View {
        switch m.role {
        case .user:
            VStack(alignment: .trailing, spacing: 4) {
                if let refs = m.refs {
                    ForEach(refs, id: \.self) { name in
                        Label(name, systemImage: "doc.text").font(.callout).lineLimit(1)
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(.quaternary, in: Capsule())
                    }
                }
                if !m.images.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(Array(m.images.enumerated()), id: \.offset) { Thumbnail(data: $1, size: 72) }
                    }
                }
                if !m.text.isEmpty {
                    Text(m.text)
                        .textSelection(.enabled)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
            }
            .padding(.leading, 40)
            .frame(maxWidth: .infinity, alignment: .trailing)
        case .assistant:
            let live = chat.running && m.id == chat.messages.last?.id
            // 圖表的 HTML 區塊回完才會取出存檔，串流中先藏起來
            let fence = m.text.range(of: "```" + AssistantChat.diagramFence)
            let text = AssistantChat.hidingCleanup(fence.map { String(m.text[..<$0.lowerBound]) } ?? m.text)
            VStack(alignment: .leading, spacing: 6) {
                if !text.isEmpty || live {
                    Group {
                        if text.isEmpty {
                            working(drawing: fence != nil)
                        } else {
                            VStack(alignment: .leading, spacing: 4) {
                                ReplyText(text: Self.linked(text))
                                // 已經吐出一段但還沒講完（例如 codex 一段一段回），點點留著表示還在想
                                if live { working(drawing: fence != nil) }
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                if let d = m.diagram { DiagramCard(url: chat.diagramURL(d)) }
                if !live, let instruction = AssistantChat.cleanupInstruction(in: m.text) {
                    Button { startCleanup(instruction) } label: {
                        Label(L("套用到逐字稿…", "Apply to Transcript…"), systemImage: "wand.and.sparkles")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(cleanup != nil)
                    .help(L("照這個指示逐句修改，看過再套用", "Edit each line this way, then review before applying"))
                }
                // 講完才給複製，複製的是原始 markdown
                if !m.text.isEmpty, !live {
                    Button {
                        NSPasteboard.general.clearContents()
                        // codex 的檔案引用標記換成路徑，貼到別處才看得懂
                        let text = AssistantChat.hidingCleanup(m.text).replacing(#/:codex-file-citation\{[^}]*?path="([^"]+)"[^}]*\}/#) { String($0.1) }
                        NSPasteboard.general.setString(text, forType: .string)
                        copied = m.id
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { if copied == m.id { copied = nil } }
                    } label: {
                        Image(systemName: copied == m.id ? "checkmark" : "doc.on.doc").font(.system(size: 12)).foregroundStyle(.secondary)
                            .frame(width: 22, height: 20)
                    }
                    .buttonStyle(.borderless)
                    .help(L("複製", "Copy"))
                    .padding(.leading, 4)
                }
            }
            .padding(.trailing, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
        case .error:
            Label(m.text, systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(.red)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// 工具列按鈕的圖示：裝了哪些工具就疊哪些的標誌
private struct AssistantMarks: View {
    let kinds: [AssistantKind]

    var body: some View {
        HStack(spacing: -6) {
            // 一個都沒裝：兩個灰色空圓
            if kinds.isEmpty {
                ForEach(0..<2, id: \.self) { _ in
                    Circle().strokeBorder(.secondary, lineWidth: 1.2).frame(width: 19, height: 19)
                }
            }
            ForEach(Array(kinds.enumerated()), id: \.element) { i, k in
                Image(nsImage: k.mark)
                    .resizable()
                    .renderingMode(.template)
                    .foregroundStyle(k == .claude ? Color.white : Color.black)
                    .padding(k == .claude ? 3 : 3.5)
                    .frame(width: 19, height: 19)
                    .background(k == .claude ? Color(red: 0.85, green: 0.47, blue: 0.34) : Color.white, in: Circle())
                    // 白底在淺色工具列上會糊掉，描一圈淡灰
                    .overlay(Circle().strokeBorder(k == .claude ? Color.clear : Color.black.opacity(0.15), lineWidth: 0.5))
                    .overlay(Circle().strokeBorder(Color(nsColor: .windowBackgroundColor), lineWidth: 1.2).padding(-1.2))
                    .zIndex(Double(-i))
            }
        }
    }
}

extension AssistantKind {
    var mark: NSImage {
        NSImage(contentsOf: Bundle.main.resourceURL!.appendingPathComponent("icons/\(rawValue).svg")) ?? NSImage()
    }
}

/// AI 回覆的文字。SwiftUI 的 Text 可選取時游標永遠是 I 字、點 file:// 連結也沒反應，所以改用 NSTextView：
/// 連結上會變手指，點了用預設 app 打開
private struct ReplyText: NSViewRepresentable {
    let text: AttributedString

    func makeNSView(context: Context) -> NSTextView {
        let v = NSTextView(usingTextLayoutManager: false)
        v.isEditable = false
        v.isSelectable = true
        v.drawsBackground = false
        v.textContainerInset = .zero
        v.textContainer?.lineFragmentPadding = 0
        v.linkTextAttributes = [.foregroundColor: NSColor.linkColor, .underlineStyle: NSUnderlineStyle.single.rawValue, .cursor: NSCursor.pointingHand]
        v.textContainer?.widthTracksTextView = false
        v.isVerticallyResizable = false
        v.delegate = context.coordinator
        // SwiftUI 會先量尺寸才呼叫 updateNSView，文字要一開始就放進去
        updateNSView(v, context: context)
        return v
    }

    func updateNSView(_ v: NSTextView, context: Context) {
        guard context.coordinator.shown != text else { return }
        context.coordinator.shown = text
        v.textStorage?.setAttributedString(Self.appKit(text))
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView v: NSTextView, context: Context) -> CGSize? {
        guard let container = v.textContainer, let layout = v.layoutManager else { return nil }
        container.size = NSSize(width: proposal.width ?? .greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        layout.ensureLayout(for: container)
        let used = layout.usedRect(for: container)
        // usedRect 的寬度一律是整個容器寬，短回覆的泡泡要貼著字，寬度另外量
        let width = v.attributedString().boundingRect(with: container.size, options: [.usesLineFragmentOrigin, .usesFontLeading]).width
        return CGSize(width: ceil(width), height: ceil(used.height))
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var shown: AttributedString?
        private var last: (url: URL, at: Date)?

        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            guard let url = link as? URL ?? (link as? String).flatMap(URL.init(string:)) else { return false }
            // 連點或手抖點兩下只開一次
            if let last, last.url == url, Date().timeIntervalSince(last.at) < 1.5 { return true }
            last = (url, Date())
            NSWorkspace.shared.open(url)
            return true
        }
    }

    /// markdown 解析出來的區塊（標題、清單、引用、程式碼、表格）排成段落，粗體、斜體、程式碼轉成 AppKit 字型，連結保留
    private static func appKit(_ text: AttributedString) -> NSAttributedString {
        let size = NSFont.systemFontSize
        let indent: CGFloat = 18
        let out = NSMutableAttributedString()
        var paragraph: Int?
        var listed = [Int: Int]()  // 清單項目 → 它第一段的段落
        var tables: [Int: NSTextTable] = [:]
        for run in text.runs {
            let blocks = run.presentationIntent?.components ?? []
            var piece = String(text[run.range].characters)
            var font = NSFont.systemFont(ofSize: size)
            var color = NSColor.labelColor
            let style = NSMutableParagraphStyle()
            style.lineSpacing = 2
            style.paragraphSpacing = 6
            var depth = 0, marker: String?
            // components 由內往外排，從外層開始套
            for (i, b) in blocks.enumerated().reversed() {
                switch b.kind {
                case .header(let level):
                    font = .boldSystemFont(ofSize: size + max(0, CGFloat(4 - level) * 2))
                    style.paragraphSpacingBefore = 4
                case .listItem(let ordinal):
                    depth += 1
                    style.paragraphSpacing = 3
                    // 只有清單項目的第一段要標記
                    if listed[b.identity, default: blocks[0].identity] == blocks[0].identity {
                        listed[b.identity] = blocks[0].identity
                        var ordered = false
                        if i + 1 < blocks.count, case .orderedList = blocks[i + 1].kind { ordered = true }
                        marker = ordered ? "\(ordinal)." : (depth > 1 ? "◦" : "•")
                    }
                case .blockQuote:
                    depth += 1
                    color = .secondaryLabelColor
                case .codeBlock:
                    font = .monospacedSystemFont(ofSize: size - 1, weight: .regular)
                    if piece.hasSuffix("\n") { piece.removeLast() }
                case .thematicBreak:
                    color = .tertiaryLabelColor
                case .table(let columns):
                    let table = tables[b.identity] ?? NSTextTable()
                    table.numberOfColumns = columns.count
                    table.collapsesBorders = true
                    tables[b.identity] = table
                case .tableHeaderRow:
                    font = .boldSystemFont(ofSize: size)
                default: break
                }
            }
            if let table = blocks.compactMap({ tables[$0.identity] }).first {
                var row = 0, column = 0
                for b in blocks {
                    if case .tableCell(let c) = b.kind { column = c }
                    if case .tableRow(let r) = b.kind { row = r }
                }
                let cell = NSTextTableBlock(table: table, startingRow: row, rowSpan: 1, startingColumn: column, columnSpan: 1)
                cell.setWidth(0.5, type: .absoluteValueType, for: .border)
                cell.setBorderColor(.separatorColor)
                cell.setWidth(4, type: .absoluteValueType, for: .padding)
                style.textBlocks = [cell]
                style.paragraphSpacing = 0
            }
            style.headIndent = CGFloat(depth) * indent
            style.firstLineHeadIndent = style.headIndent
            let id = blocks.first?.identity
            if marker != nil {
                style.firstLineHeadIndent = CGFloat(depth - 1) * indent
                style.tabStops = [NSTextTab(textAlignment: .left, location: style.headIndent)]
            }
            // 段落裡的換行（硬換行、程式碼）改成行分隔符，才不會每行都多出段距
            piece = piece.replacingOccurrences(of: "\n", with: "\u{2028}")
            // 換段落時補換行，換行沿用上一段的樣式（表格的格子靠它收尾）
            if let id, id != paragraph {
                if paragraph != nil, out.length > 0 {
                    out.append(NSAttributedString(string: "\n", attributes: out.attributes(at: out.length - 1, effectiveRange: nil)))
                }
                paragraph = id
                if let marker {
                    out.append(NSAttributedString(string: marker + "\t", attributes: [.font: NSFont.systemFont(ofSize: size), .foregroundColor: color, .paragraphStyle: style]))
                }
            }
            let intent = run.inlinePresentationIntent ?? []
            if intent.contains(.code) { font = .monospacedSystemFont(ofSize: font.pointSize - 1, weight: .regular) }
            if intent.contains(.stronglyEmphasized) { font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) }
            if intent.contains(.emphasized) { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
            var attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: style]
            if intent.contains(.strikethrough) { attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            if let link = run.link { attrs[.link] = link }
            out.append(NSAttributedString(string: piece, attributes: attrs))
        }
        return out
    }
}

/// 對話裡的圖片縮圖，裁成正方形
private struct Thumbnail: View {
    let data: Data
    let size: CGFloat

    var body: some View {
        Image(nsImage: NSImage(data: data) ?? NSImage())
            .resizable()
            .scaledToFill()
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.separator))
    }
}

/// 等回覆時的三個點，像「訊息」的對方正在輸入
private struct TypingDots: View {
    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 4) {
                ForEach(0..<3) { i in
                    Circle()
                        .frame(width: 7, height: 7)
                        .opacity(0.3 + 0.6 * max(0, sin((t * 2 - Double(i) * 0.35) * .pi)))
                }
            }
            .foregroundStyle(.secondary)
            .padding(.vertical, 5)
        }
    }
}

/// 工具列的開始／停止錄音
private struct RecordButton: View {
    @ObservedObject private var library = Library.shared

    var body: some View {
        if library.live == nil {
            Button { library.startLive() } label: { mark(Circle(), "REC") }
                .help(L("開始錄音：瀏覽器在開會就連會議聲音一起錄，否則只錄麥克風", "Start recording: captures meeting audio too if a browser meeting is active, otherwise just the microphone"))
        } else {
            Button { library.stopLive() } label: { mark(RoundedRectangle(cornerRadius: 2), "STOP") }
                .help(L("停止錄音並存檔", "Stop recording and save"))
        }
    }

    private func mark(_ shape: some Shape, _ text: String) -> some View {
        HStack(spacing: 5) {
            shape.fill(.red).frame(width: 10, height: 10)
            Text(text).font(.system(size: 12, weight: .bold, design: .rounded)).foregroundStyle(.red)
        }
        .padding(.horizontal, 4)
    }
}

/// 這個畫面本身要盯著播放器：有沒有畫面是載入後才查到的，只看 model 不會重畫
private struct VideoSlot: View {
    @ObservedObject var player: DashboardPlayer
    let url: URL
    let editor: TranscriptEditor?

    var body: some View {
        if player.hasVideo && player.url == url { VideoPane(player: player, editor: editor) }
    }
}

/// 匯入的影片：畫面放在逐字稿上方，正在播的那一句疊在下面當字幕。
/// 控制列用系統的浮動樣式，滑鼠移上去才出現（播放、拖進度、全螢幕）；全螢幕時字幕跟著走。下緣可以拖拉調整高度
private struct VideoPane: View {
    let player: DashboardPlayer
    let editor: TranscriptEditor?
    @AppStorage("videoHeight") private var height: Double = 280
    @State private var dragStart: Double?

    var body: some View {
        VStack(spacing: 0) {
            VideoPlayer(player: player.player, subtitle: editor.map { Subtitle(editor: $0, playing: $0.playing) })
                .frame(maxWidth: .infinity)
                .frame(height: height)
                .background(.black)
            // 拖拉調整高度的把手，看起來跟一般分隔線一樣
            Divider()
                .padding(.vertical, 3)
                .contentShape(Rectangle())
                .padding(.vertical, -3)
                .onHover { inside in if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() } }
                .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global).onChanged { v in
                    let start = dragStart ?? height
                    dragStart = start
                    height = min(max(start + v.translation.height, 140), 900)
                }.onEnded { _ in dragStart = nil })
                .help(L("拖拉調整影片大小", "Drag to resize the video"))
        }
    }

    private struct VideoPlayer: NSViewRepresentable {
        let player: AVPlayer
        let subtitle: Subtitle?

        func makeNSView(context: Context) -> AVPlayerView {
            let view = AVPlayerView()
            view.player = player
            view.controlsStyle = .floating
            view.showsFullScreenToggleButton = true
            view.videoGravity = .resizeAspect
            // 字幕放在 contentOverlayView：全螢幕時一起帶過去
            if let subtitle, let overlay = view.contentOverlayView {
                let host = PassThroughHostingView(rootView: subtitle)
                host.translatesAutoresizingMaskIntoConstraints = false
                overlay.addSubview(host)
                NSLayoutConstraint.activate([
                    host.leadingAnchor.constraint(equalTo: overlay.leadingAnchor),
                    host.trailingAnchor.constraint(equalTo: overlay.trailingAnchor),
                    host.topAnchor.constraint(equalTo: overlay.topAnchor),
                    host.bottomAnchor.constraint(equalTo: overlay.bottomAnchor),
                ])
            }
            return view
        }

        func updateNSView(_ view: AVPlayerView, context: Context) {}
    }

    /// 字幕不接滑鼠，點擊和控制列照常給影片
    private final class PassThroughHostingView: NSHostingView<Subtitle> {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    struct Subtitle: View {
        @ObservedObject var editor: TranscriptEditor
        @ObservedObject var playing: TranscriptEditor.Playing

        var body: some View {
            GeometryReader { g in
                // 全螢幕時字變大；底下留位置給浮動控制列
                let size = min(max(g.size.height / 18, 15), 40)
                VStack {
                    Spacer()
                    if let id = playing.id, let s = editor.transcript.segments.first(where: { $0.id == id }), !s.text.isEmpty {
                        Text(s.text)
                            .font(.system(size: size, weight: .medium))
                            .foregroundStyle(.white)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, size * 0.6)
                            .padding(.vertical, size * 0.25)
                            .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
                            .padding(.horizontal, 24)
                            .padding(.bottom, max(56, g.size.height * 0.1))
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
    }
}

/// AI 整理逐字稿的審閱畫面：改過的句子一列一列，原文劃掉、新的在下面；勾選的才套用
private struct CleanupView: View {
    @ObservedObject var cleanup: TranscriptCleanup
    let seek: (Double) -> Void
    let close: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            status.padding(14)
            Divider()
            if cleanup.changes.isEmpty {
                if cleanup.phase == .review {
                    ContentUnavailableView(L("沒有需要修改的地方", "Nothing to Change"), systemImage: "checkmark.circle")
                } else {
                    Spacer()
                }
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach($cleanup.changes) { $c in
                            row($c)
                            Divider()
                        }
                    }
                }
            }
            Divider()
            footer.padding(12)
        }
    }

    @ViewBuilder private var status: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(L("整理逐字稿", "Clean Up Transcript"), systemImage: "wand.and.sparkles").font(.headline)
            if cleanup.instruction != TranscriptCleanup.instruction {
                Text(cleanup.instruction).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            }
            switch cleanup.phase {
            case .running(let done, let total):
                ProgressView(value: Double(done), total: Double(total))
                // 時間到才重算剩幾秒
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    Text(cleanup.remaining.map { L("已修改 \(cleanup.changes.count) 句 · 大約還要 \(Self.duration($0))", "\(cleanup.changes.count) changed · about \(Self.duration($0)) left") }
                         ?? L("正在讀逐字稿…", "Reading the transcript…"))
                        .font(.callout).foregroundStyle(.secondary)
                }
            case .review:
                if !cleanup.changes.isEmpty {
                    Text(L("勾選要套用的修改，點時間可以聽那一句。", "Check the changes to apply. Click a time to hear that line."))
                        .font(.callout).foregroundStyle(.secondary)
                }
            case .applied(let n):
                Text(L("已套用 \(n) 句。", "Applied \(n) changes.")).font(.callout).foregroundStyle(.secondary)
            case .failed(let message):
                Text(message).font(.callout).foregroundStyle(.red).textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func row(_ c: Binding<TranscriptCleanup.Change>) -> some View {
        let applied = if case .applied = cleanup.phase { true } else { false }
        return HStack(alignment: .top, spacing: 10) {
            Toggle("", isOn: c.accepted).toggleStyle(.checkbox).labelsHidden().disabled(applied)
            VStack(alignment: .leading, spacing: 4) {
                Button(Transcript.clock(c.wrappedValue.start)) { seek(c.wrappedValue.start) }
                    .buttonStyle(.plain)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Color.accentColor)
                    .onHover { inside in if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() } }
                    .help(L("跳到這一句", "Jump to this line"))
                Text(c.wrappedValue.original).strikethrough().foregroundStyle(.secondary)
                Text(c.wrappedValue.revised)
            }
            .textSelection(.enabled)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .opacity(c.wrappedValue.accepted ? 1 : 0.5)
    }

    @ViewBuilder private var footer: some View {
        HStack {
            switch cleanup.phase {
            case .running:
                Spacer()
                Button(L("停止", "Stop")) { cleanup.cancel(); close() }
            case .review:
                Button(L("捨棄", "Discard"), action: close)
                Spacer()
                if !cleanup.changes.isEmpty {
                    let all = cleanup.changes.allSatisfy(\.accepted)
                    Button(all ? L("全不選", "Select None") : L("全選", "Select All")) {
                        for i in cleanup.changes.indices { cleanup.changes[i].accepted = !all }
                    }
                    let n = cleanup.changes.filter(\.accepted).count
                    Button(L("套用 \(n) 句", "Apply \(n)")) { cleanup.apply() }
                        .buttonStyle(.borderedProminent)
                        .disabled(n == 0)
                } else {
                    Button(L("完成", "Done"), action: close).buttonStyle(.borderedProminent)
                }
            case .applied:
                Button(L("復原", "Undo"), action: cleanup.undo)
                Spacer()
                Button(L("完成", "Done"), action: close).buttonStyle(.borderedProminent)
            case .failed:
                Spacer()
                Button(L("關閉", "Close"), action: close)
            }
        }
    }

    static func duration(_ s: Int) -> String {
        s < 60 ? L("\(max(s, 1)) 秒", "\(max(s, 1))s") : L("\(s / 60) 分 \(s % 60) 秒", "\(s / 60)m \(s % 60)s")
    }
}
