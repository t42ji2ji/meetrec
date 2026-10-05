import AppKit
import SwiftUI

struct DashboardView: View {
    @ObservedObject var model: DashboardModel
    @State private var renameText = ""

    var body: some View {
        NavigationSplitView {
            SidebarView(model: model)
                .navigationSplitViewColumnWidth(min: 220, ideal: 270, max: 400)
        } detail: {
            DetailView(model: model)
        }
        .navigationTitle("MeetRec")
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button { model.importWithPanel() } label: { Label("匯入…", systemImage: "square.and.arrow.down") }
                    .help("匯入音檔或影片（也可以直接拖進視窗）")
            }
            ToolbarItem(placement: .primaryAction) { RecordButton() }
            // 放在最外層、一直都在：切換錄音時工具列不用重建
            ToolbarItemGroup(placement: .primaryAction) {
                let r = model.selectedRecording
                let has = r.map(model.hasTranscript) ?? false
                let busy = r.map { model.status[$0.url].map { if case .failed = $0 { false } else { true } } ?? false } ?? false
                Button { model.retranscribing = r } label: { Label("重新轉錄", systemImage: "arrow.clockwise") }
                    .help("重新轉逐字稿（會蓋掉手動修改）")
                    .disabled(!has || busy)
                Menu {
                    Button("匯出 SRT…") { if let r { model.export(r, as: .srt) } }
                    Button("匯出 TXT…") { if let r { model.export(r, as: .txt) } }
                } label: { Label("匯出", systemImage: "square.and.arrow.up") }
                    .help("匯出逐字稿")
                    .disabled(!has)
                Button { if let r { model.reveal(r) } } label: { Label("在 Finder 中顯示", systemImage: "folder") }
                    .help("在 Finder 中顯示")
                    .disabled(r == nil)
            }
        }
        .overlay {
            if model.dropTargeted {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [8, 6]))
                    .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                    .overlay { Label("放開就匯入並轉逐字稿", systemImage: "square.and.arrow.down").font(.title2.weight(.medium)) }
                    .padding(8)
                    .allowsHitTesting(false)
            }
        }
        .alert("重新命名", isPresented: present($model.renaming)) {
            TextField("名稱", text: $renameText)
            Button("取消", role: .cancel) {}
            Button("好") { if let r = model.renaming { model.rename(r, to: renameText) } }
        }
        .onChange(of: model.renaming) { _, r in if let r { renameText = r.title } }
        .alert("要把「\(model.deleting?.title ?? "")」移到垃圾桶嗎？", isPresented: present($model.deleting)) {
            Button("取消", role: .cancel) {}
            Button("移到垃圾桶", role: .destructive) { if let r = model.deleting { model.delete(r) } }
        } message: {
            Text("整個資料夾（音檔、逐字稿、SRT、TXT）會一起移到垃圾桶。")
        }
        .alert("要重新轉逐字稿嗎？", isPresented: present($model.retranscribing)) {
            Button("取消", role: .cancel) {}
            Button("重新轉錄", role: .destructive) { if let r = model.retranscribing { model.transcribe(r) } }
        } message: {
            Text("新的逐字稿會蓋掉現在的版本，包括手動改過的文字和說話者名稱。")
        }
        .alert("出了點問題", isPresented: present($model.error)) {
            Button("好") {}
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
                Section("錄音中") {
                    LiveRow(live: live).tag(DashboardSelection.live)
                }
            }
            if !items.isEmpty {
                Section(model.search.isEmpty ? "錄音" : "搜尋結果") {
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
                    Label("還沒有錄音", systemImage: "waveform")
                } description: {
                    Text("瀏覽器開始用麥克風時 MeetRec 會問要不要錄。也可以把音檔或影片拖進來。")
                } actions: {
                    Button("匯入…") { model.importWithPanel() }
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
        f.placeholderString = "搜尋標題或逐字稿"
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
                Text(live.paused ? "已暫停 · \(Transcript.clock(live.elapsed))" : Transcript.clock(live.elapsed))
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
                Text("轉錄中 \(Int(p * 100))%")
            }
        case .queued:
            Text("排隊中")
        case .failed:
            Label("失敗", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
        case nil:
            if !hasTranscript { Text("尚未轉錄").foregroundStyle(.tertiary) }
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
        Button("重新命名…") { model.renaming = recording }
        Button("在 Finder 中顯示") { model.reveal(recording) }
        Divider()
        Button(has ? "重新轉逐字稿…" : "轉逐字稿") {
            if has { model.retranscribing = recording } else { model.transcribe(recording) }
        }
        .disabled(busy)
        Button("匯出 SRT…") { model.export(recording, as: .srt) }.disabled(!has)
        Button("匯出 TXT…") { model.export(recording, as: .txt) }.disabled(!has)
        Divider()
        Button("移到垃圾桶…", role: .destructive) { model.deleting = recording }
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
                ContentUnavailableView("找不到這場錄音", systemImage: "questionmark.folder", description: Text("檔案可能被移走或刪掉了。"))
            }
        case nil:
            ContentUnavailableView("選一場錄音", systemImage: "waveform", description: Text("在左邊選一場錄音來播放、看逐字稿。"))
        }
    }
}

private struct LiveDetail: View {
    @ObservedObject private var library = Library.shared

    var body: some View {
        if let live = library.live {
            content(live)
        } else {
            ProgressView("正在存檔…")
        }
    }

    private func content(_ live: Library.Live) -> some View {
        VStack(spacing: 18) {
            Label(live.paused ? "已暫停" : "錄音中", systemImage: live.paused ? "pause.circle.fill" : "record.circle")
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
                    Label(live.paused ? "繼續" : "暫停", systemImage: live.paused ? "play.fill" : "pause.fill").frame(minWidth: 90)
                }
                Button { Library.shared.stopLive() } label: {
                    Label("停止並存檔", systemImage: "stop.fill").frame(minWidth: 110)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
            }
            .controlSize(.large)
            Text("存檔後會自動轉逐字稿").font(.callout).foregroundStyle(.tertiary)
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
            TextField("標題", text: $title)
                .textFieldStyle(.plain)
                .font(.title2.weight(.semibold))
                .focused($editingTitle)
                .onSubmit { commitTitle() }
                .onExitCommand { title = recording.title; editingTitle = false }
                .onChange(of: editingTitle) { _, editing in if !editing { commitTitle() } }
                .help("點一下改名")
            HStack(spacing: 8) {
                Label(recording.dateText, systemImage: "calendar")
                Label(Transcript.clock(recording.duration), systemImage: "clock")
                if let n = model.editor?.transcript.speakerOrder.count, n > 1 {
                    Label("\(n) 位說話者", systemImage: "person.2")
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
                        Label("轉逐字稿失敗", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(message)
                    } actions: {
                        Button("重試") { model.transcribe(recording) }
                    }
                case nil:
                    ContentUnavailableView {
                        Label("還沒有逐字稿", systemImage: "text.bubble")
                    } description: {
                        Text("轉好之後可以點時間跳著聽、修正文字和說話者。")
                    } actions: {
                        Button("開始轉逐字稿") { model.transcribe(recording) }
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
                Text("正在轉逐字稿… \(Int(p * 100))%").font(.callout.monospacedDigit())
                ProgressView(value: p)
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text("排隊中，等前面的轉完").font(.callout)
                ProgressView().progressViewStyle(.linear)
            }
        }
    }

    private func failedBanner(_ message: String) -> some View {
        HStack {
            Label("重新轉錄失敗：\(message)", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
            Spacer()
            Button("重試") { model.transcribe(recording) }
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
                .help("倒退 15 秒")
            Button { player.toggle() } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.title2)
                    .frame(width: 26)
            }
            .help(player.isPlaying ? "暫停（空白鍵）" : "播放（空白鍵）")
            Button { player.skip(15) } label: { Image(systemName: "goforward.15") }
                .help("快轉 15 秒")
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
            Picker("速度", selection: $player.rate) {
                ForEach([Float(1), 1.25, 1.5, 2], id: \.self) { r in
                    Text(r == 1 ? "1x" : r == 2 ? "2x" : "\(r, specifier: "%g")x").tag(r)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
            .help("播放速度")
        }
        .font(.body)
        .buttonStyle(.borderless)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .disabled(player.url == nil)
        .background(.bar)
    }
}

/// 工具列的開始／停止錄音
private struct RecordButton: View {
    @ObservedObject private var library = Library.shared

    var body: some View {
        if library.live == nil {
            Button { library.startLive() } label: { Label("開始錄音", systemImage: "record.circle") }
                .help("開始錄音：瀏覽器在開會就連會議聲音一起錄，否則只錄麥克風")
        } else {
            Button { library.stopLive() } label: { Label("停止並存檔", systemImage: "stop.circle.fill") }
                .help("停止錄音並存檔")
                .tint(.red)
        }
    }
}
