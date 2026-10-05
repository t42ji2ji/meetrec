import AppKit
import Combine
import SwiftUI

/// 一場錄音的逐字稿編輯：改字、改說話者、改名字。改完一秒沒動作就存（Library.save 會順便更新 srt/txt）
@MainActor
final class TranscriptEditor: ObservableObject {
    /// 正在播的那一句。獨立一個物件：播放時只有每一列自己的反白會更新，整個清單不用重算
    final class Playing: ObservableObject {
        @Published var id: UUID?
    }

    /// 畫面上的一列。段首＝同一個人連續講的第一句，那一段的句子 id 記在段首
    struct Row: Identifiable, Equatable {
        var segment: Transcript.Segment
        var isHead: Bool
        var turn: [UUID]
        var id: UUID { segment.id }
    }

    let recording: Library.Recording
    let playing = Playing()
    @Published private(set) var transcript: Transcript
    /// transcript 變動時算一次，畫面每次重畫直接用
    @Published private(set) var rows: [Row] = []
    private(set) var talk: [String: Double] = [:]
    /// 最後一次和磁碟一致的版本
    private var saved: Transcript
    private var saveTask: Task<Void, Never>?
    private var index: [UUID: Int] = [:]
    private let onError: (String) -> Void
    private var bag = Set<AnyCancellable>()

    init(recording: Library.Recording, transcript: Transcript, clock: DashboardPlayer.Clock, onError: @escaping (String) -> Void) {
        self.recording = recording
        self.transcript = transcript
        saved = transcript
        self.onError = onError
        rebuild()
        clock.$time.sink { [weak self] t in
            guard let self else { return }
            let id = segment(at: t)
            if id != playing.id { playing.id = id }
        }.store(in: &bag)
    }

    private func rebuild() {
        let segs = transcript.segments
        index = Dictionary(uniqueKeysWithValues: segs.enumerated().map { ($1.id, $0) })
        var rows: [Row] = []
        var talk: [String: Double] = [:]
        var head = 0
        for (i, s) in segs.enumerated() {
            talk[s.speaker, default: 0] += max(0, s.end - s.start)
            if i > 0, segs[i - 1].speaker == s.speaker {
                rows[head].turn.append(s.id)
                rows.append(Row(segment: s, isHead: false, turn: []))
            } else {
                head = rows.count
                rows.append(Row(segment: s, isHead: true, turn: [s.id]))
            }
        }
        self.rows = rows
        self.talk = talk
    }

    /// 最後一句已經開始、還沒講完（或剛講完一秒內）的
    private func segment(at t: Double) -> UUID? {
        guard t > 0, let s = transcript.segments.last(where: { $0.start <= t + 0.05 }), t < s.end + 1 else { return nil }
        return s.id
    }

    /// 出場順序，加上新增了但還沒用到的
    var speakerKeys: [String] {
        let order = transcript.speakerOrder
        return order + transcript.speakers.keys.filter { !order.contains($0) }.sorted()
    }

    func displayName(_ key: String) -> String {
        let n = transcript.name(key)
        return n.isEmpty ? "未命名" : n
    }

    // MARK: 編輯

    func text(_ id: UUID) -> String {
        index[id].map { transcript.segments[$0].text } ?? ""
    }

    /// 打字只改那一列，不重建整個清單
    func setText(_ id: UUID, _ text: String) {
        guard let i = index[id], transcript.segments[i].text != text else { return }
        transcript.segments[i].text = text
        rows[i].segment.text = text
        scheduleSave()
    }

    func assign(_ ids: [UUID], to speaker: String) {
        for id in ids { if let i = index[id] { transcript.segments[i].speaker = speaker } }
        rebuild()
        flush()
    }

    func renameSpeaker(_ key: String, to name: String) {
        let name = name.trimmingCharacters(in: .whitespaces)
        guard transcript.speakers[key] != name else { return }
        transcript.speakers[key] = name
        flush()
    }

    /// 新的 key 沿用這份逐字稿的前綴（them／s），編號接在最大的後面，顏色才不會跟既有的撞
    func addSpeaker(named name: String) -> String {
        let keys = Set(transcript.speakers.keys).union(transcript.speakerOrder)
        let prefix = keys.contains { $0.hasPrefix("them") } ? "them" : "s"
        let n = keys.compactMap { $0.hasPrefix(prefix) ? Int($0.dropFirst(prefix.count)) : nil }.max() ?? 0
        let key = "\(prefix)\(n + 1)"
        transcript.speakers[key] = name.trimmingCharacters(in: .whitespaces)
        return key
    }

    // MARK: 存檔

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }

    func flush() {
        saveTask?.cancel()
        guard transcript != saved else { return }
        do {
            try Library.shared.save(transcript, for: recording)
            saved = transcript
        } catch {
            onError("逐字稿存檔失敗：\(error)")
        }
    }

    /// 要重新轉錄了，還沒存的修改不要再寫回去
    func discardPending() {
        saveTask?.cancel()
        saved = transcript
    }

    /// 磁碟上的版本：是自己剛存的就不動；跟上次存的不一樣（重新轉錄）就換掉
    func adopt(_ disk: Transcript) {
        if disk == transcript {
            saved = disk
        } else if disk != saved {
            saveTask?.cancel()
            transcript = disk
            saved = disk
            rebuild()
        }
    }
}

/// 同一個 key 永遠同一個顏色：「我」藍色，其他人照編號輪
func speakerColor(_ key: String) -> Color {
    if key == "me" { return .blue }
    let palette: [Color] = [.orange, .green, .purple, .pink, .teal, .brown, .indigo, .mint, .red, .cyan]
    let n = Int(key.drop { !$0.isNumber }) ?? key.unicodeScalars.reduce(0) { $0 + Int($1.value) }
    return palette[(n + palette.count - 1) % palette.count]
}

struct SpeakerChip: View {
    let name: String
    let key: String
    var body: some View {
        Text(name)
            .font(.callout.weight(.medium))
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .foregroundStyle(speakerColor(key))
            .background(speakerColor(key).opacity(0.15), in: Capsule())
    }
}

/// 逐字稿：上面說話者（點名字直接改名），下面一句一行。平常每句是純文字，點下去那一句才換成輸入框
struct TranscriptView: View {
    enum Field: Hashable {
        case segment(UUID)
        case speaker(String)
    }

    @ObservedObject var editor: TranscriptEditor
    let player: DashboardPlayer
    @FocusState private var focus: Field?
    @State private var editingID: UUID?
    /// 點下去的位置（螢幕座標），輸入框出現後把游標放在那裡
    @State private var clickedAt: NSPoint?
    @State private var editingSpeaker: String?
    @State private var nameText = ""
    @State private var userScrolledAt = Date.distantPast
    @State private var addingFor: [UUID]?

    var body: some View {
        VStack(spacing: 0) {
            legend
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(editor.rows) { row in
                            SegmentRow(row: row, playing: editor.playing,
                                       speaker: editor.displayName(row.segment.speaker),
                                       editing: editingID == row.id ? Binding(get: { editor.text(row.id) }, set: { editor.setText(row.id, $0) }) : nil,
                                       focus: $focus,
                                       play: { focus = nil; player.seek(row.segment.start); player.play() },
                                       edit: { clickedAt = NSEvent.mouseLocation; editingID = row.id },
                                       focused: { placeCaret() },
                                       menu: { showMenu(for: row) })
                                .padding(.top, row.isHead ? 10 : 0)
                        }
                    }
                    .padding(12)
                }
                .onScrollPhaseChange { old, new in
                    // 使用者自己捲過就先不要自動捲回播放位置
                    if [old, new].contains(where: { $0 == .interacting || $0 == .decelerating }) { userScrolledAt = Date() }
                }
                .onReceive(editor.playing.$id.removeDuplicates()) { id in
                    guard let id, player.isPlaying, editingID == nil, Date().timeIntervalSince(userScrolledAt) > 4 else { return }
                    withAnimation(.easeInOut(duration: 0.3)) { proxy.scrollTo(id, anchor: .center) }
                }
            }
        }
        .onChange(of: focus) { old, new in
            // 離開輸入框（Return、Esc、點別的地方）就收回成文字並存檔
            if case .segment(let id) = old, new != old {
                editor.flush()
                if editingID == id { editingID = nil }
            }
            if case .speaker(let key) = old, new != old {
                if editingSpeaker == key {
                    editor.renameSpeaker(key, to: nameText)
                    editingSpeaker = nil
                }
            }
        }
        .alert("新增說話者", isPresented: Binding(get: { addingFor != nil }, set: { if !$0 { addingFor = nil } })) {
            TextField("名稱", text: $nameText)
            Button("取消", role: .cancel) {}
            Button("新增") {
                if let ids = addingFor { editor.assign(ids, to: editor.addSpeaker(named: nameText)) }
            }
        } message: {
            Text("新增後這句會改成這個人說的。")
        }
    }

    private var legend: some View {
        let total = max(editor.talk.values.reduce(0, +), 1)
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 16) {
                ForEach(editor.transcript.speakerOrder, id: \.self) { key in
                    HStack(spacing: 6) {
                        if editingSpeaker == key {
                            TextField("名稱", text: $nameText)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 120)
                                .focused($focus, equals: .speaker(key))
                                .onSubmit { focus = nil }
                                .onExitCommand { editingSpeaker = nil; focus = nil }
                                .onAppear { DispatchQueue.main.async { focus = .speaker(key) } }
                        } else {
                            LegendName(name: editor.displayName(key), key: key) { renameSpeaker(key) }
                        }
                        let t = editor.talk[key] ?? 0
                        Text("\(Transcript.clock(t)) · \(Int((t / total * 100).rounded()))%")
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
        }
    }

    /// 輸入框拿到焦點時系統會全選，直接打字就把整句蓋掉；改成把游標放在點的位置
    private func placeCaret() {
        guard let p = clickedAt, let w = NSApp.keyWindow, let tv = w.firstResponder as? NSTextView else { return }
        clickedAt = nil
        let i = tv.characterIndexForInsertion(at: tv.convert(w.convertPoint(fromScreen: p), from: nil))
        tv.setSelectedRange(NSRange(location: min(i, (tv.string as NSString).length), length: 0))
    }

    private func renameSpeaker(_ key: String) {
        nameText = editor.transcript.name(key)
        editingSpeaker = key
    }

    /// 說話者選單用 AppKit 現做：幾百列的 SwiftUI Menu 每次切換錄音都要建，太慢
    private func showMenu(for row: TranscriptEditor.Row) {
        let menu = NSMenu()
        let current = row.segment.speaker
        let others = editor.speakerKeys.filter { $0 != current }
        if !others.isEmpty {
            menu.addItem(.sectionHeader(title: "這句改成"))
            for k in others {
                menu.addItem(MenuItem(editor.displayName(k)) { editor.assign([row.id], to: k) })
            }
            if row.isHead, row.turn.count > 1 {
                let whole = NSMenuItem(title: "整段 \(row.turn.count) 句改成", action: nil, keyEquivalent: "")
                whole.submenu = NSMenu()
                for k in others {
                    whole.submenu?.addItem(MenuItem(editor.displayName(k)) { editor.assign(row.turn, to: k) })
                }
                menu.addItem(whole)
            }
            menu.addItem(.separator())
        }
        menu.addItem(MenuItem("重新命名「\(editor.displayName(current))」…") { renameSpeaker(current) })
        menu.addItem(MenuItem("新增說話者…") { nameText = ""; addingFor = [row.id] })
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }
}

/// 說話者統計上的名字：點一下就地改名
private struct LegendName: View {
    let name: String
    let key: String
    let rename: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: rename) {
            HStack(spacing: 3) {
                SpeakerChip(name: name, key: key)
                Image(systemName: "pencil")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .opacity(hovering ? 1 : 0)
            }
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("點一下改名")
    }
}

private struct SegmentRow: View {
    let row: TranscriptEditor.Row
    @ObservedObject var playing: TranscriptEditor.Playing
    let speaker: String
    /// 正在改這一句才有
    let editing: Binding<String>?
    var focus: FocusState<TranscriptView.Field?>.Binding
    let play: () -> Void
    let edit: () -> Void
    let focused: () -> Void
    let menu: () -> Void
    @State private var hovering = false

    var body: some View {
        let isPlaying = playing.id == row.id
        // 每列只用 Text＋點擊手勢，不用 Button／help：幾十列一起建立時差很多
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(Transcript.clock(row.segment.start))
                .font(.callout.monospacedDigit())
                .foregroundStyle(isPlaying ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .frame(width: 58, alignment: .trailing)
                .contentShape(Rectangle())
                .onTapGesture(perform: play)
                .pointerStyle(.link)

            // 每段第一句顯示說話者；後面的句子滑過才出現，一樣可以單獨改
            SpeakerChip(name: speaker, key: row.segment.speaker)
                .onTapGesture(perform: menu)
                .pointerStyle(.link)
                .frame(width: 112, alignment: .leading)
                .opacity(row.isHead ? 1 : hovering ? 0.6 : 0)

            if let editing {
                TextField("", text: editing, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineSpacing(3)
                    .focused(focus, equals: .segment(row.id))
                    .onSubmit { focus.wrappedValue = nil }
                    .onExitCommand { focus.wrappedValue = nil }
                    // 輸入框剛出現時還沒掛進視窗，等下一輪再要焦點
                    .onAppear {
                        DispatchQueue.main.async {
                            focus.wrappedValue = .segment(row.id)
                            DispatchQueue.main.async(execute: focused)
                        }
                    }
            } else {
                // 只有字本身能點進編輯；字以外的空白交給整列的點擊（跳到這句播放）
                Text(row.segment.text.isEmpty ? " " : row.segment.text)
                    .lineSpacing(3)
                    .onTapGesture(perform: edit)
                    .pointerStyle(.horizontalText)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(isPlaying ? Color.accentColor.opacity(0.12) : hovering ? Color.primary.opacity(0.04) : .clear,
                    in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        // 正在改這一句時整列不接點擊，點輸入框裡移游標才不會變成跳播
        .gesture(TapGesture().onEnded(play), including: editing == nil ? .all : .subviews)
        .onHover { hovering = $0 }
        .id(row.id)
    }
}
