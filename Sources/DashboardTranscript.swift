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
    /// ⌥⌘F 的取代列
    @Published var replacing = false
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

    /// 這個人的每一段發言（連續講的算一段）：開始時間和開頭幾個字
    func turns(of speaker: String) -> [(id: UUID, start: Double, preview: String)] {
        rows.filter { $0.isHead && $0.segment.speaker == speaker }.map { row in
            let text = row.turn.compactMap { index[$0].map { transcript.segments[$0].text } }.joined(separator: "，")
            return (row.id, row.segment.start, String(text.prefix(30)))
        }
    }

    /// 出場順序，加上新增了但還沒用到的
    var speakerKeys: [String] {
        let order = transcript.speakerOrder
        return order + transcript.speakers.keys.filter { !order.contains($0) }.sorted()
    }

    func colorIndex(_ key: String) -> Int {
        transcript.colors?[key] ?? defaultColorIndex(key)
    }

    func color(_ key: String) -> Color { speakerPalette[colorIndex(key) % speakerPalette.count] }

    func setColor(_ key: String, _ index: Int) {
        guard colorIndex(key) != index else { return }
        transcript.colors = (transcript.colors ?? [:]).merging([key: index]) { $1 }
        flush()
    }

    func displayName(_ key: String) -> String {
        let n = transcript.name(key)
        return n.isEmpty ? L("未命名", "Untitled") : n
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

    /// 編輯模式：同一個人連續講的句子接成一段。句子之間依停頓長短補標點、分段，只是顯示用，存檔時會拿掉
    func turnText(_ ids: [UUID]) -> String {
        let parts = ids.map(text)
        let seps = separators(ids)
        return parts.enumerated().map { $1 + ($0 < seps.count ? seps[$0] : "") }.joined()
    }

    /// 編輯模式改了整段：拆回原本的句子，時間才對得上
    func setTurnText(_ ids: [UUID], _ new: String) {
        for (id, t) in zip(ids, Self.redistribute(ids.map(text), separators(ids), into: new)) { setText(id, t) }
    }

    /// 第 k 句和下一句之間放什麼。whisper 的句子首尾相接（上一句結束＝下一句開始），只有真的沒人講話才有空檔，
    /// 所以中文句子之間一律「，」，停超過 1.5 秒「。」；停超過 3 秒或這段累積 150 字就換段。
    /// 句子本來就有標點或是英文時不補標點
    private func separators(_ ids: [UUID]) -> [String] {
        let segs = ids.compactMap { index[$0].map { transcript.segments[$0] } }
        var seps: [String] = [], length = 0
        for k in segs.indices.dropLast() {
            let gap = segs[k + 1].start - segs[k].end
            length += segs[k].text.count
            let cjk = segs[k].text.last.map { !$0.isASCII && !$0.isPunctuation } ?? false
            if gap > 3 || length >= 150 {
                seps.append((cjk ? "。" : "") + "\n\n")
                length = 0
            } else if cjk, gap > 1.5 {
                seps.append("。")
            } else if cjk {
                seps.append("，")
            } else {
                // 中文標點後面不用空格
                seps.append(segs[k].text.last.map { !$0.isASCII && $0.isPunctuation } ?? false ? "" : " ")
            }
        }
        return seps
    }

    /// 比對改前（句子用 seps 接起來）和改後，句子之間的切點跟著旁邊的字移動：
    /// 打在切點前面的字算前一句，後面的算下一句。補上去的標點、換行在切點後面，拆回去時從下一句開頭去掉
    nonisolated static func redistribute(_ parts: [String], _ seps: [String], into new: String) -> [String] {
        guard parts.count > 1 else { return [new.trimmingCharacters(in: .whitespacesAndNewlines)] }
        let old = Array(zip(parts, seps + [""]).map { $0 + $1 }.joined()), now = Array(new)
        var removed = Set<Int>(), inserted = Set<Int>()
        for change in now.difference(from: old) {
            switch change {
            case .remove(let o, _, _): removed.insert(o)
            case .insert(let o, _, _): inserted.insert(o)
            }
        }
        // 舊的第 i 個字在新字串裡的位置
        var map = [Int](repeating: 0, count: old.count + 1)
        var j = 0
        for i in 0...old.count {
            while inserted.contains(j) { j += 1 }
            map[i] = j
            if i < old.count, !removed.contains(i) { j += 1 }
        }
        var cuts: [Int] = [], at = 0
        for (p, sep) in zip(parts.dropLast(), seps) {
            at += p.count
            cuts.append(map[at])
            at += sep.count
        }
        let bounds = [0] + cuts + [now.count]
        let added = CharacterSet(charactersIn: "，。").union(.whitespacesAndNewlines)
        return (0..<parts.count).map { k in
            var t = Substring(String(now[min(bounds[k], bounds[k + 1])..<bounds[k + 1]]))
            if k > 0 { t = t.drop { $0.unicodeScalars.allSatisfy(added.contains) } }
            return t.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    /// 取代列：幾處符合（不分大小寫）
    func count(_ find: String) -> Int {
        guard !find.isEmpty else { return 0 }
        return transcript.segments.reduce(0) { n, s in
            var r = s.text.startIndex..<s.text.endIndex, c = 0
            while let m = s.text.range(of: find, options: .caseInsensitive, range: r) { c += 1; r = m.upperBound..<s.text.endIndex }
            return n + c
        }
    }

    func replaceAll(_ find: String, with replacement: String) {
        guard !find.isEmpty else { return }
        for i in transcript.segments.indices {
            transcript.segments[i].text = transcript.segments[i].text.replacingOccurrences(of: find, with: replacement, options: .caseInsensitive)
        }
        rebuild()
        flush()
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
            onError(L("逐字稿存檔失敗：\(error)", "Couldn’t save transcript: \(error)"))
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

/// 說話者可選的顏色；順序不能改，逐字稿存的是索引
let speakerPalette: [Color] = [.blue, .orange, .green, .purple, .pink, .teal, .brown, .indigo, .mint, .red, .cyan, .gray]

/// 沒挑過顏色時：「我」藍色，其他人照編號從橘色開始輪
func defaultColorIndex(_ key: String) -> Int {
    if key == "me" { return 0 }
    let n = Int(key.drop { !$0.isNumber }) ?? key.unicodeScalars.reduce(0) { $0 + Int($1.value) }
    return 1 + (n + 9) % 10
}

struct SpeakerChip: View {
    let name: String
    let color: Color
    var body: some View {
        Text(name)
            .font(.callout.weight(.medium))
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .foregroundStyle(color)
            .background(color.opacity(0.15), in: Capsule())
    }
}

/// 逐字稿：上面說話者（點名字直接改名），下面一句一行。平常每句是純文字，點下去那一句才換成輸入框
struct TranscriptView: View {
    enum Field: Hashable {
        case segment(UUID)
        /// 編輯模式的一段，用段首那句的 id
        case turn(UUID)
    }

    /// 逐句：一句一列、有時間；編輯：同一個人連續講的併成一段，一直是輸入框，改字快
    enum Mode: String { case segments, editor }

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
    /// 從說話者發言清單跳過去的那一句，捲到它
    @State private var jumpTo: UUID?
    @AppStorage("transcriptFontSize") private var fontSize = Settings.defaultFontSize
    @AppStorage("transcriptMode") private var mode = Mode.segments

    var body: some View {
        VStack(spacing: 0) {
            if editor.replacing {
                ReplaceBar(editor: editor)
                Divider()
            }
            HStack(spacing: 0) {
                legend
                Picker(L("檢視", "View"), selection: $mode) {
                    Text(L("逐句", "Segments")).tag(Mode.segments)
                    Text(L("編輯", "Editor")).tag(Mode.editor)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Button { editor.replacing.toggle() } label: { Image(systemName: "text.magnifyingglass") }
                    .buttonStyle(.borderless)
                    .help(L("尋找並取代（⌥⌘F）", "Find and Replace (⌥⌘F)"))
                    .padding(.leading, 10)
                    .padding(.trailing, 20)
            }
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    Group {
                    if mode == .editor {
                        turns
                    } else {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(editor.rows) { row in
                            SegmentRow(row: row, playing: editor.playing,
                                       speaker: editor.displayName(row.segment.speaker),
                                       color: editor.color(row.segment.speaker),
                                       editing: editingID == row.id ? Binding(get: { editor.text(row.id) }, set: { editor.setText(row.id, $0) }) : nil,
                                       focus: $focus,
                                       play: { focus = nil; player.seek(row.segment.start) },
                                       edit: {
                                           clickedAt = NSEvent.mouseLocation
                                           CaretPlacer.shared.arm(at: NSEvent.mouseLocation)
                                           editingID = row.id
                                       },
                                       focused: { placeCaret() },
                                       menu: { showMenu(for: row) })
                                .padding(.top, row.isHead ? 10 : 0)
                        }
                    }
                    }
                    }
                    // 只有沒自己指定字型的句子內文會跟著變；時間、說話者維持原大小
                    .font(.system(size: fontSize))
                    .padding(12)
                }
                .onScrollPhaseChange { old, new in
                    // 使用者自己捲過就先不要自動捲回播放位置
                    if [old, new].contains(where: { $0 == .interacting || $0 == .decelerating }) { userScrolledAt = Date() }
                }
                .onChange(of: jumpTo) { _, id in
                    guard let id else { return }
                    withAnimation(.easeInOut(duration: 0.3)) { proxy.scrollTo(id, anchor: .center) }
                    jumpTo = nil
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
            if case .turn = old, new != old { editor.flush() }
        }
        .alert(L("新增說話者", "Add Speaker"), isPresented: Binding(get: { addingFor != nil }, set: { if !$0 { addingFor = nil } })) {
            TextField(L("名稱", "Name"), text: $nameText)
            Button(L("取消", "Cancel"), role: .cancel) {}
            Button(L("新增", "Add")) {
                if let ids = addingFor { editor.assign(ids, to: editor.addSpeaker(named: nameText)) }
            }
        } message: {
            Text(L("新增後這句會改成這個人說的。", "This line will be reassigned to the new speaker."))
        }
    }

    private var turns: some View {
        LazyVStack(alignment: .leading, spacing: 30) {
            ForEach(editor.rows.filter(\.isHead)) { row in
                VStack(alignment: .leading, spacing: 4) {
                    // 編輯模式的重點是文字，說話者只用淡淡的小字標
                    Text(editor.displayName(row.segment.speaker))
                        .font(.caption.weight(.medium))
                        .foregroundStyle(editor.color(row.segment.speaker).opacity(0.7))
                        .onTapGesture { showMenu(for: row) }
                        .pointerStyle(.link)
                    TurnField(ids: row.turn, editor: editor, focus: $focus)
                }
                .padding(.horizontal, 8)
            }
        }
        .padding(.top, 8)
    }

    private var legend: some View {
        let total = max(editor.talk.values.reduce(0, +), 1)
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 16) {
                ForEach(editor.transcript.speakerOrder, id: \.self) { key in
                    HStack(spacing: 6) {
                        LegendName(name: editor.displayName(key), color: editor.color(key)) { editingSpeaker = key }
                            .popover(isPresented: Binding(get: { editingSpeaker == key }, set: { if !$0 { editingSpeaker = nil } }),
                                     arrowEdge: .bottom) {
                                SpeakerEditor(editor: editor, key: key)
                            }
                        let t = editor.talk[key] ?? 0
                        TalkTimeButton(label: "\(Transcript.clock(t)) · \(Int((t / total * 100).rounded()))%",
                                       turns: { editor.turns(of: key) }) { turn in
                            focus = nil
                            userScrolledAt = .distantPast
                            jumpTo = turn.id
                            player.seek(turn.start)
                        }
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

    /// 說話者選單用 AppKit 現做：幾百列的 SwiftUI Menu 每次切換錄音都要建，太慢
    private func showMenu(for row: TranscriptEditor.Row) {
        let menu = NSMenu()
        let current = row.segment.speaker
        let others = editor.speakerKeys.filter { $0 != current }
        if !others.isEmpty, mode == .editor {
            menu.addItem(.sectionHeader(title: L("這段改成", "Change This Passage To")))
            for k in others {
                menu.addItem(MenuItem(editor.displayName(k)) { editor.assign(row.turn, to: k) })
            }
            menu.addItem(.separator())
        } else if !others.isEmpty {
            menu.addItem(.sectionHeader(title: L("這句改成", "Change This Line To")))
            for k in others {
                menu.addItem(MenuItem(editor.displayName(k)) { editor.assign([row.id], to: k) })
            }
            if row.isHead, row.turn.count > 1 {
                let whole = NSMenuItem(title: L("整段 \(row.turn.count) 句改成", "Change All \(row.turn.count) Lines To"), action: nil, keyEquivalent: "")
                whole.submenu = NSMenu()
                for k in others {
                    whole.submenu?.addItem(MenuItem(editor.displayName(k)) { editor.assign(row.turn, to: k) })
                }
                menu.addItem(whole)
            }
            menu.addItem(.separator())
        }
        menu.addItem(MenuItem(L("重新命名「\(editor.displayName(current))」…", "Rename “\(editor.displayName(current))”…")) { editingSpeaker = current })
        menu.addItem(MenuItem(L("新增說話者…", "Add Speaker…")) { nameText = ""; addingFor = [row.id] })
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }
}

/// 輸入框拿到焦點時 AppKit 會先把整句全選，等下一輪才移游標的話會閃一下反白。
/// 改成在全選發生的當下（還沒畫到畫面上）就換成點的位置
@MainActor
final class CaretPlacer {
    static let shared = CaretPlacer()
    private var point: NSPoint?
    private var observer: NSObjectProtocol?
    private var generation = 0

    func arm(at screenPoint: NSPoint) {
        disarm()
        point = screenPoint
        observer = NotificationCenter.default.addObserver(forName: NSTextView.didChangeSelectionNotification, object: nil, queue: nil) { note in
            MainActor.assumeIsolated { CaretPlacer.shared.selectionChanged(note.object as? NSTextView) }
        }
        // 半秒內沒等到全選就放棄，之後的選取都是使用者自己的
        generation += 1
        let g = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { if self.generation == g { self.disarm() } }
    }

    private func selectionChanged(_ tv: NSTextView?) {
        guard let tv, tv.isFieldEditor, let p = point, let w = tv.window else { return }
        let len = (tv.string as NSString).length
        guard len > 0, tv.selectedRange().length == len else { return }
        disarm()
        let i = tv.characterIndexForInsertion(at: tv.convert(w.convertPoint(fromScreen: p), from: nil))
        tv.setSelectedRange(NSRange(location: min(i, len), length: 0))
    }

    private func disarm() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        point = nil
    }
}

/// ⌥⌘F：整份逐字稿一次取代
private struct ReplaceBar: View {
    @ObservedObject var editor: TranscriptEditor
    @State private var find = ""
    @State private var replacement = ""
    @FocusState private var findFocused: Bool

    var body: some View {
        let n = editor.count(find)
        HStack(spacing: 8) {
            TextField(L("尋找", "Find"), text: $find)
                .textFieldStyle(.roundedBorder)
                .focused($findFocused)
            TextField(L("取代為", "Replace with"), text: $replacement)
                .textFieldStyle(.roundedBorder)
                .onSubmit { if n > 0 { editor.replaceAll(find, with: replacement) } }
            Text(find.isEmpty ? "" : L("\(n) 處", n == 1 ? "1 match" : "\(n) matches"))
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 64, alignment: .trailing)
            Button(L("全部取代", "Replace All")) { editor.replaceAll(find, with: replacement) }
                .disabled(n == 0)
            Button { editor.replacing = false } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                .buttonStyle(.borderless)
                .help(L("關閉（Esc）", "Close (Esc)"))
        }
        .onExitCommand { editor.replacing = false }
        .controlSize(.regular)
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .onAppear { findFocused = true }
    }
}

/// 編輯模式的一段。打字時用自己的草稿：存回去的版本會把空白整理掉，直接綁會讓人打不出句尾的空白
private struct TurnField: View {
    let ids: [UUID]
    @ObservedObject var editor: TranscriptEditor
    var focus: FocusState<TranscriptView.Field?>.Binding
    @State private var draft: String?

    var body: some View {
        TextField("", text: Binding(get: { draft ?? editor.turnText(ids) }, set: { draft = $0; editor.setTurnText(ids, $0) }), axis: .vertical)
            .textFieldStyle(.plain)
            .lineSpacing(3)
            .focused(focus, equals: .turn(ids[0]))
            .onSubmit { focus.wrappedValue = nil }
            .onChange(of: focus.wrappedValue) { _, f in if f != .turn(ids[0]) { draft = nil } }
    }
}

/// 說話者統計上的時長：點一下列出這個人每段發言，點一段就跳過去播
private struct TalkTimeButton: View {
    typealias Turn = (id: UUID, start: Double, preview: String)
    let label: String
    let turns: () -> [Turn]
    let jump: (Turn) -> Void
    @State private var showing = false
    @State private var hovering = false

    var body: some View {
        Button { showing = true } label: {
            Text(label)
                .font(.callout.monospacedDigit())
                .foregroundStyle(hovering || showing ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .underline(hovering)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .pointerStyle(.link)
        .help(L("看這個人每段發言，點一段跳過去", "See each of this speaker’s turns; click one to jump to it"))
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            let list = turns()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(list, id: \.id) { turn in
                        TurnRow(turn: turn) {
                            showing = false
                            jump(turn)
                        }
                    }
                }
                .padding(6)
            }
            .frame(width: 340, height: min(CGFloat(list.count) * 30 + 12, 360))
        }
    }
}

private struct TurnRow: View {
    let turn: TalkTimeButton.Turn
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Text(Transcript.clock(turn.start))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 52, alignment: .trailing)
                Text(turn.preview)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(height: 30)
            .contentShape(Rectangle())
            .background(hovering ? Color.accentColor.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .pointerStyle(.link)
    }
}

/// 點說話者名字跳出來的小視窗：改名、挑顏色。關掉（Return、點外面）就存名字，Esc 放棄改名
private struct SpeakerEditor: View {
    @ObservedObject var editor: TranscriptEditor
    let key: String
    @State private var name = ""
    @State private var cancelled = false
    @FocusState private var focused: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            TextField(L("名稱", "Name"), text: $name, prompt: Text(L("不標說話者", "No label")))
                .textFieldStyle(.plain)
                .font(.title3.weight(.semibold))
                .foregroundStyle(editor.color(key))
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(editor.color(key).opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .focused($focused)
                .onSubmit { dismiss() }
                .onExitCommand { cancelled = true; dismiss() }
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(24), spacing: 10), count: 6), alignment: .leading, spacing: 10) {
                ForEach(speakerPalette.indices, id: \.self) { i in
                    let selected = editor.colorIndex(key) == i
                    Circle()
                        .fill(speakerPalette[i])
                        .frame(width: 18, height: 18)
                        .padding(3)
                        .overlay(Circle().strokeBorder(speakerPalette[i], lineWidth: 2).opacity(selected ? 1 : 0))
                        .contentShape(Circle())
                        .onTapGesture { editor.setColor(key, i) }
                        .pointerStyle(.link)
                }
            }
        }
        .padding(14)
        .frame(width: 236)
        .onAppear {
            name = editor.transcript.name(key)
            focused = true
        }
        .onDisappear { if !cancelled { editor.renameSpeaker(key, to: name) } }
    }
}

/// 說話者統計上的名字：點一下改名、挑顏色
private struct LegendName: View {
    let name: String
    let color: Color
    let rename: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: rename) {
            HStack(spacing: 3) {
                SpeakerChip(name: name, color: color)
                Image(systemName: "pencil")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .opacity(hovering ? 1 : 0)
            }
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(L("點一下改名", "Click to rename"))
    }
}

private struct SegmentRow: View {
    let row: TranscriptEditor.Row
    @ObservedObject var playing: TranscriptEditor.Playing
    let speaker: String
    let color: Color
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
            SpeakerChip(name: speaker, color: color)
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
        .pointerStyle(editing == nil ? .link : nil)
        .onHover { hovering = $0 }
        .id(row.id)
    }
}
