import Combine
import SwiftUI

/// 一場錄音的逐字稿編輯：改字、改說話者、改名字。改完一秒沒動作就存（Library.save 會順便更新 srt/txt）
@MainActor
final class TranscriptEditor: ObservableObject {
    let recording: Library.Recording
    @Published private(set) var transcript: Transcript
    /// 正在播的那一句
    @Published private(set) var playingID: UUID?
    /// 最後一次和磁碟一致的版本
    private var saved: Transcript
    private var saveTask: Task<Void, Never>?
    private var index: [UUID: Int] = [:]
    private let onError: (String) -> Void
    private var bag = Set<AnyCancellable>()

    /// 同一個人連續講的併成一段
    struct Turn: Identifiable {
        let speaker: String
        var segments: [Transcript.Segment]
        var id: UUID { segments[0].id }
    }

    init(recording: Library.Recording, transcript: Transcript, clock: DashboardPlayer.Clock, onError: @escaping (String) -> Void) {
        self.recording = recording
        self.transcript = transcript
        saved = transcript
        self.onError = onError
        reindex()
        clock.$time.sink { [weak self] t in
            guard let self else { return }
            let id = segment(at: t)
            if id != playingID { playingID = id }
        }.store(in: &bag)
    }

    private func reindex() {
        index = Dictionary(uniqueKeysWithValues: transcript.segments.enumerated().map { ($1.id, $0) })
    }

    /// 最後一句已經開始、還沒講完（或剛講完一秒內）的
    private func segment(at t: Double) -> UUID? {
        guard t > 0, let s = transcript.segments.last(where: { $0.start <= t + 0.05 }), t < s.end + 1 else { return nil }
        return s.id
    }

    var turns: [Turn] {
        var turns: [Turn] = []
        for s in transcript.segments {
            if let last = turns.last, last.speaker == s.speaker {
                turns[turns.count - 1].segments.append(s)
            } else {
                turns.append(Turn(speaker: s.speaker, segments: [s]))
            }
        }
        return turns
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

    func talkTime(_ key: String) -> Double {
        transcript.segments.filter { $0.speaker == key }.reduce(0) { $0 + max(0, $1.end - $1.start) }
    }

    // MARK: 編輯

    func text(_ id: UUID) -> String {
        index[id].map { transcript.segments[$0].text } ?? ""
    }

    func setText(_ id: UUID, _ text: String) {
        guard let i = index[id], transcript.segments[i].text != text else { return }
        transcript.segments[i].text = text
        scheduleSave()
    }

    func assign(_ ids: [UUID], to speaker: String) {
        for id in ids { if let i = index[id] { transcript.segments[i].speaker = speaker } }
        flush()
    }

    func renameSpeaker(_ key: String, to name: String) {
        transcript.speakers[key] = name.trimmingCharacters(in: .whitespaces)
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
            reindex()
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

/// 逐字稿：上面說話者統計，下面一句一行
struct TranscriptView: View {
    @ObservedObject var editor: TranscriptEditor
    let player: DashboardPlayer
    @FocusState private var focused: UUID?
    @State private var userScrolledAt = Date.distantPast
    @State private var renamingSpeaker: String?
    @State private var addingFor: [UUID]?
    @State private var nameText = ""

    var body: some View {
        VStack(spacing: 0) {
            legend
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(editor.turns) { turn in
                            ForEach(Array(turn.segments.enumerated()), id: \.element.id) { i, s in
                                SegmentRow(editor: editor, segment: s, turn: turn, isHead: i == 0, isPlaying: editor.playingID == s.id,
                                           focused: $focused, play: { player.seek(s.start); player.play() },
                                           rename: { renamingSpeaker = $0; nameText = editor.transcript.name($0) },
                                           add: { addingFor = $0; nameText = "" })
                                    .padding(.top, i == 0 ? 10 : 0)
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 12)
                }
                .onScrollPhaseChange { old, new in
                    // 使用者自己捲過就先不要自動捲回播放位置
                    if [old, new].contains(where: { $0 == .interacting || $0 == .decelerating }) { userScrolledAt = Date() }
                }
                .onChange(of: editor.playingID) { _, id in
                    guard let id, player.isPlaying, focused == nil, Date().timeIntervalSince(userScrolledAt) > 4 else { return }
                    withAnimation(.easeInOut(duration: 0.3)) { proxy.scrollTo(id, anchor: .center) }
                }
            }
        }
        .onChange(of: focused) { old, _ in
            if old != nil { editor.flush() }
        }
        .alert("重新命名說話者", isPresented: Binding(get: { renamingSpeaker != nil }, set: { if !$0 { renamingSpeaker = nil } })) {
            TextField("名稱", text: $nameText)
            Button("取消", role: .cancel) {}
            Button("好") { if let k = renamingSpeaker { editor.renameSpeaker(k, to: nameText) } }
        } message: {
            Text("這個人說的每一句都會改成新名稱。留空就不標說話者。")
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
        let total = max(editor.transcript.segments.reduce(0) { $0 + max(0, $1.end - $1.start) }, 1)
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 14) {
                ForEach(editor.transcript.speakerOrder, id: \.self) { key in
                    Menu {
                        Button("重新命名說話者…") { renamingSpeaker = key; nameText = editor.transcript.name(key) }
                    } label: {
                        HStack(spacing: 6) {
                            SpeakerChip(name: editor.displayName(key), key: key)
                            let t = editor.talkTime(key)
                            Text("\(Transcript.clock(t)) · \(Int((t / total * 100).rounded()))%")
                                .font(.callout.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("點一下重新命名")
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
        }
    }
}

private struct SegmentRow: View {
    @ObservedObject var editor: TranscriptEditor
    let segment: Transcript.Segment
    let turn: TranscriptEditor.Turn
    let isHead: Bool
    let isPlaying: Bool
    var focused: FocusState<UUID?>.Binding
    let play: () -> Void
    let rename: (String) -> Void
    let add: ([UUID]) -> Void
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Button(action: play) {
                Text(Transcript.clock(segment.start))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(isPlaying ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    .frame(width: 58, alignment: .trailing)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("從這裡播放")
            .accessibilityLabel("從 \(Transcript.clock(segment.start)) 播放")

            // 每段第一句顯示說話者；後面的句子滑過才出現，一樣可以單獨改
            speakerMenu
                .frame(width: 112, alignment: .leading)
                .opacity(isHead ? 1 : hovering ? 0.6 : 0)

            TextField("", text: Binding(get: { editor.text(segment.id) }, set: { editor.setText(segment.id, $0) }), axis: .vertical)
                .textFieldStyle(.plain)
                .font(.body)
                .lineSpacing(3)
                .focused(focused, equals: segment.id)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(isPlaying ? Color.accentColor.opacity(0.12) : hovering ? Color.primary.opacity(0.04) : .clear,
                    in: RoundedRectangle(cornerRadius: 6))
        .onHover { hovering = $0 }
        .id(segment.id)
    }

    private var speakerMenu: some View {
        let others = editor.speakerKeys.filter { $0 != segment.speaker }
        return Menu {
            if !others.isEmpty {
                Section("這句改成") {
                    ForEach(others, id: \.self) { k in
                        Button(editor.displayName(k)) { editor.assign([segment.id], to: k) }
                    }
                }
            }
            if isHead, turn.segments.count > 1 {
                Menu("整段 \(turn.segments.count) 句改成") {
                    ForEach(others, id: \.self) { k in
                        Button(editor.displayName(k)) { editor.assign(turn.segments.map(\.id), to: k) }
                    }
                }
            }
            Divider()
            Button("重新命名說話者「\(editor.displayName(segment.speaker))」…") { rename(segment.speaker) }
            Button("新增說話者…") { add([segment.id]) }
        } label: {
            SpeakerChip(name: editor.displayName(segment.speaker), key: segment.speaker)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}
