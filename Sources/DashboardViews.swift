import AppKit
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
            ToolbarItem(placement: .navigation) {
                Button { model.importWithPanel() } label: { Label(L("匯入…", "Import…"), systemImage: "square.and.arrow.down") }
                    .help(L("匯入音檔或影片（也可以直接拖進視窗）", "Import audio or video (or drag files into the window)"))
            }
            ToolbarItem(placement: .primaryAction) { RecordButton() }
            // 放在最外層、一直都在：切換錄音時工具列不用重建
            ToolbarItemGroup(placement: .primaryAction) {
                let r = model.selectedRecording
                let has = r.map(model.hasTranscript) ?? false
                let busy = r.map { model.status[$0.url].map { if case .failed = $0 { false } else { true } } ?? false } ?? false
                Button { model.retranscribing = r } label: { Label(L("重新轉錄", "Re-transcribe"), systemImage: "arrow.clockwise") }
                    .help(L("重新轉逐字稿（會蓋掉手動修改）", "Re-transcribe (overwrites manual edits)"))
                    .disabled(!has || busy)
                Menu {
                    Button(L("匯出 SRT…", "Export SRT…")) { if let r { model.export(r, as: .srt) } }
                    Button(L("匯出 TXT…", "Export TXT…")) { if let r { model.export(r, as: .txt) } }
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
        .onChange(of: model.renaming) { _, r in if let r { renameText = r.title } }
        .alert(L("要把「\(model.deleting?.title ?? "")」移到垃圾桶嗎？", "Move “\(model.deleting?.title ?? "")” to the Trash?"), isPresented: present($model.deleting)) {
            Button(L("取消", "Cancel"), role: .cancel) {}
            Button(L("移到垃圾桶", "Move to Trash"), role: .destructive) { if let r = model.deleting { model.delete(r) } }
        } message: {
            Text(L("整個資料夾（音檔、逐字稿、SRT、TXT）會一起移到垃圾桶。", "The whole folder (audio, transcript, SRT, TXT) will be moved to the Trash."))
        }
        .alert(L("要重新轉逐字稿嗎？", "Re-transcribe this recording?"), isPresented: present($model.retranscribing)) {
            Button(L("取消", "Cancel"), role: .cancel) {}
            Button(L("重新轉錄", "Re-transcribe"), role: .destructive) { if let r = model.retranscribing { model.transcribe(r) } }
        } message: {
            Text(L("新的逐字稿會蓋掉現在的版本，包括手動改過的文字和說話者名稱。", "The new transcript will replace the current one, including any text and speaker names you edited."))
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

    var body: some View {
        let items = model.visibleRecordings
        List(selection: Binding(get: { model.selection }, set: { model.pick($0) })) {
            if let live = library.live {
                Section(L("錄音中", "Recording")) {
                    LiveRow(live: live).tag(DashboardSelection.live)
                }
            }
            if !items.isEmpty {
                Section(model.search.isEmpty ? L("錄音", "Recordings") : L("搜尋結果", "Search Results")) {
                    ForEach(items) { r in
                        RecordingRow(recording: r, status: library.status[r.url], hasTranscript: model.hasTranscript(r), snippet: model.snippet(for: r))
                            .tag(DashboardSelection.recording(r.url))
                            .contextMenu { RecordingActions(model: model, recording: r) }
                    }
                }
            }
        }
        // 不用 .searchable：它在 NavigationSplitView 裡會收集每一欄的 preference，每次切換錄音都把整份逐字稿清單排版一遍
        .safeAreaInset(edge: .top) {
            SearchField(text: $model.search, model: model)
                .padding(.horizontal, 10)
                .padding(.bottom, 4)
        }
        .overlay {
            if library.recordings.isEmpty && library.live == nil {
                ContentUnavailableView {
                    Label(L("還沒有錄音", "No Recordings Yet"), systemImage: "waveform")
                } description: {
                    Text(L("瀏覽器開始用麥克風時 MeetRec 會問要不要錄。也可以把音檔或影片拖進來。", "MeetRec asks whether to record when your browser starts using the microphone. You can also drag audio or video files here."))
                } actions: {
                    Button(L("匯入…", "Import…")) { model.importWithPanel() }
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

private struct RecordingRow: View {
    let recording: Library.Recording
    let status: Library.Status?
    let hasTranscript: Bool
    let snippet: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(recording.title).lineLimit(1).truncationMode(.middle).help(recording.title)
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

    @ViewBuilder private var statusView: some View {
        switch status {
        case .transcribing(let p):
            HStack(spacing: 4) {
                ProgressView(value: p).frame(width: 36).controlSize(.mini)
                Text(L("轉錄中 \(Int(p * 100))%", "Transcribing \(Int(p * 100))%"))
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
        Divider()
        Button(has ? L("重新轉逐字稿…", "Re-transcribe…") : L("轉逐字稿", "Transcribe")) {
            if has { model.retranscribing = recording } else { model.transcribe(recording) }
        }
        .disabled(busy)
        Button(L("匯出 SRT…", "Export SRT…")) { model.export(recording, as: .srt) }.disabled(!has)
        Button(L("匯出 TXT…", "Export TXT…")) { model.export(recording, as: .txt) }.disabled(!has)
        Divider()
        Button(L("移到垃圾桶…", "Move to Trash…"), role: .destructive) { model.deleting = recording }
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
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            PlayerBar(player: model.player, clock: model.player.clock)
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
                .onExitCommand { title = recording.title; editingTitle = false }
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
        .onAppear { title = recording.title; titleURL = recording.url }
        .onChange(of: recording.url) { old, _ in
            // 改到一半就切到別場：改名還是套用到原本那一場
            let t = title.trimmingCharacters(in: .whitespaces)
            if titleURL == old, let r = model.library.recordings.first(where: { $0.url == old }), !t.isEmpty, t != r.title {
                model.rename(r, to: t)
            }
            title = recording.title
            titleURL = recording.url
        }
    }

    private func commitTitle() {
        guard titleURL == recording.url else { return }
        let t = title.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, t != recording.title else {
            title = recording.title
            return
        }
        model.rename(recording, to: t)
        // 失敗的話（例如名稱重複）改回原來的
        if model.error != nil { title = recording.title }
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
                    }
                case nil:
                    ContentUnavailableView {
                        Label(L("還沒有逐字稿", "No Transcript Yet"), systemImage: "text.bubble")
                    } description: {
                        Text(L("轉好之後可以點時間跳著聽、修正文字和說話者。", "Once transcribed, you can click timestamps to jump around and fix text and speakers."))
                    } actions: {
                        Button(L("開始轉逐字稿", "Transcribe")) { model.transcribe(recording) }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                    }
                }
            }
        }
    }

    @ViewBuilder private var progressBanner: some View {
        if case .transcribing(let p) = status {
            VStack(alignment: .leading, spacing: 6) {
                Text(L("正在轉逐字稿… \(Int(p * 100))%", "Transcribing… \(Int(p * 100))%")).font(.callout.monospacedDigit())
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
            Slider(value: Binding(get: { dragging ?? clock.time }, set: { dragging = $0 }),
                   in: 0...max(player.duration, 0.1)) { editing in
                if !editing, let d = dragging {
                    player.seek(d)
                    dragging = nil
                }
            }
            .controlSize(.small)
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

// MARK: AI 對話

private struct AssistantPanel: View {
    @ObservedObject var model: DashboardModel
    @AppStorage("assistant") private var preferred = AssistantKind.claude
    /// 各工具選的模型，空字串＝工具自己的預設
    @AppStorage("assistantModel.claude") private var claudeModel = ""
    @AppStorage("assistantModel.codex") private var codexModel = ""

    var body: some View {
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
                              send: { model.ask($0, in: chat, about: r, model: modelID.wrappedValue.isEmpty ? nil : modelID.wrappedValue) },
                              reset: { model.resetChat(for: r, kind: kind) })
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
    let send: (String) -> Void
    let reset: () -> Void
    @State private var draft = ""
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
                Button(action: reset) { Image(systemName: "square.and.pencil") }
                    .buttonStyle(.borderless)
                    .help(L("新對話", "New Chat"))
                    .disabled(chat.messages.isEmpty)
            }
            .padding(.horizontal, 14)
            .frame(height: 40)
            Divider()
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
                    ContentUnavailableView(L("問問這場會議", "Ask About This Meeting"), systemImage: "bubble.left.and.text.bubble.right")
                }
            }
            HStack(alignment: .bottom, spacing: 6) {
                TextField(L("問點什麼…", "Ask something…"), text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...8)
                    .focused($focused)
                    .onSubmit(submit)
                    .padding(.vertical, 3)
                if chat.running {
                    Button { chat.stop() } label: { Image(systemName: "stop.circle.fill").font(.system(size: 20)).foregroundStyle(.secondary) }
                        .help(L("停止", "Stop"))
                } else {
                    let empty = draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    Button(action: submit) {
                        Image(systemName: "arrow.up.circle.fill").font(.system(size: 20))
                            .foregroundStyle(empty ? AnyShapeStyle(.tertiary) : AnyShapeStyle(Color.accentColor))
                    }
                    .disabled(empty)
                    .help(L("送出（Return）", "Send (Return)"))
                }
            }
            .buttonStyle(.borderless)
            .padding(.leading, 12)
            .padding(.trailing, 5)
            .padding(.vertical, 5)
            .background(.background, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.separator))
            .padding(12)
        }
        .onAppear { focused = true }
    }

    private func submit() {
        let q = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !chat.running else { return }
        draft = ""
        send(q)
    }

    @ViewBuilder private func message(_ m: AssistantChat.Message) -> some View {
        switch m.role {
        case .user:
            Text(m.text)
                .textSelection(.enabled)
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .padding(.leading, 40)
                .frame(maxWidth: .infinity, alignment: .trailing)
        case .assistant:
            Group {
                if m.text.isEmpty {
                    TypingDots()
                } else {
                    Text((try? AttributedString(markdown: m.text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(m.text))
                        .textSelection(.enabled)
                        .lineSpacing(2)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
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
            Button { library.startLive() } label: { Label(L("開始錄音", "Start Recording"), systemImage: "record.circle") }
                .help(L("開始錄音：瀏覽器在開會就連會議聲音一起錄，否則只錄麥克風", "Start recording: captures meeting audio too if a browser meeting is active, otherwise just the microphone"))
        } else {
            Button { library.stopLive() } label: { Label(L("停止並存檔", "Stop and Save"), systemImage: "stop.circle.fill") }
                .help(L("停止錄音並存檔", "Stop recording and save"))
                .tint(.red)
        }
    }
}
