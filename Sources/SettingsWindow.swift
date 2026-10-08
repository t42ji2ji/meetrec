import AppKit
import AVFoundation
import ServiceManagement
import SwiftUI

/// 設定視窗：一般、逐字稿、模型、權限
@MainActor
final class SettingsWindow {
    static let shared = SettingsWindow()
    private var window: NSWindow?

    func show() {
        if window == nil {
            let w = EditingWindow(contentViewController: NSHostingController(rootView: SettingsView()))
            w.title = L("MeetRec 設定", "MeetRec Settings")
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            w.center()
            window = w
            NotificationCenter.default.addObserver(forName: Settings.languageChanged, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { w.title = L("MeetRec 設定", "MeetRec Settings") }
            }
        }
        // 跟主視窗一樣用強制版，從選單列點一次就跳到最前面
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

/// 只開設定視窗時 app 是選單列模式、沒有「編輯」選單，⌘V 之類的沒有人接，貼不上 API key。自己把它們送給輸入框
final class EditingWindow: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let actions: [String: Selector] = ["x": #selector(NSText.cut(_:)), "c": #selector(NSText.copy(_:)), "v": #selector(NSText.paste(_:)),
                                           "a": #selector(NSText.selectAll(_:)), "z": Selector(("undo:"))]
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           let action = event.charactersIgnoringModifiers.flatMap({ actions[$0] }),
           NSApp.sendAction(action, to: nil, from: self) {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

struct SettingsView: View {
    @ObservedObject private var models = Models.shared
    @AppStorage("language") private var language = Settings.Language.system
    @State private var transcriptLanguage = Settings.transcriptLanguage
    @State private var script = Settings.script
    @State private var vocabulary = Settings.vocabulary
    @State private var askToRecord = Settings.askToRecord
    @State private var autoTranscribe = Settings.autoTranscribe
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var mic = AVCaptureDevice.authorizationStatus(for: .audio)
    @State private var confirmDelete = false
    @AppStorage("cloudTranslation") private var cloudTranslation = false
    @State private var provider = Settings.translationProvider
    @State private var translationModel = Settings.translationModel
    @State private var apiKey = Settings.translationProvider.apiKey ?? ""
    @State private var keyCheck: KeyCheck = .idle

    @AppStorage("cloudTranscription") private var cloudTranscription = false
    @State private var service = Settings.transcriptionService
    @State private var serviceModel = Settings.transcriptionModel
    @State private var serviceKey = Settings.transcriptionService.apiKey ?? ""
    @State private var serviceCheck: KeyCheck = .idle

    private enum KeyCheck: Equatable { case idle, checking, ok, failed(String) }

    var body: some View {
        Form {
            Section(L("一般", "General")) {
                // 兩種語言都寫，切錯了也找得回來
                Picker("語言 Language", selection: Binding(get: { language }, set: { Settings.language = $0 })) {
                    ForEach(Settings.Language.allCases) { Text($0.label).tag($0) }
                }
                Toggle(L("登入時自動啟動", "Open at login"), isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        if on { try? SMAppService.mainApp.register() } else { try? SMAppService.mainApp.unregister() }
                        launchAtLogin = SMAppService.mainApp.status == .enabled
                    }
                Toggle(L("瀏覽器開始用麥克風時，問要不要錄音", "Ask to record when a browser starts using the microphone"), isOn: $askToRecord)
                    .onChange(of: askToRecord) { _, v in Settings.askToRecord = v }
                Toggle(L("錄完自動轉逐字稿", "Transcribe automatically after recording"), isOn: $autoTranscribe)
                    .onChange(of: autoTranscribe) { _, v in Settings.autoTranscribe = v }
                LabeledContent(L("錄音資料夾", "Recordings folder")) {
                    HStack {
                        Text(Library.shared.folder.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button(L("打開", "Open")) { NSWorkspace.shared.open(Library.shared.folder) }
                    }
                }
            }

            Section {
                Picker(L("語言", "Language"), selection: $transcriptLanguage) {
                    ForEach(Settings.TranscriptLanguage.allCases) { Text($0.label).tag($0) }
                }
                .onChange(of: transcriptLanguage) { _, v in Settings.transcriptLanguage = v }
                Picker(L("中文字", "Chinese script"), selection: $script) {
                    ForEach(Settings.Script.allCases) { Text($0.label).tag($0) }
                }
                .onChange(of: script) { _, v in Settings.script = v }
                VStack(alignment: .leading, spacing: 6) {
                    Text(L("常用詞", "Vocabulary"))
                    VocabularyField(text: $vocabulary)
                        .onChange(of: vocabulary) { _, v in Settings.vocabulary = v }
                }
            } header: {
                Text(L("逐字稿", "Transcript"))
            } footer: {
                Text(L("語言判錯就指定後重新轉錄。常用詞放人名、產品名、行話，幫語音模型聽對。",
                       "If the language is detected wrong, pick it and re-transcribe. Add names and jargon to Vocabulary so the speech model hears them right."))
            }

            if Translator.enabled {
            Section {
                Toggle(L("使用雲端翻譯服務", "Use a cloud translation service"), isOn: $cloudTranslation)
                if cloudTranslation {
                Picker(L("服務", "Service"), selection: $provider) {
                    ForEach(TranslationProvider.allCases) { Text($0.name).tag($0) }
                }
                .onChange(of: provider) { _, p in
                    Settings.translationProvider = p
                    translationModel = Settings.translationModel
                    apiKey = p.apiKey ?? ""
                    keyCheck = .idle
                }
                LabeledContent {
                    HStack {
                        SecureField("", text: $apiKey, prompt: Text(L("貼上 API key", "Paste API key")))
                            .labelsHidden()
                            .onChange(of: apiKey) { _, k in
                                provider.apiKey = k
                                keyCheck = .idle
                            }
                        Button(L("檢查", "Verify")) { verifyKey() }
                            .disabled(apiKey.trimmingCharacters(in: .whitespaces).isEmpty || keyCheck == .checking)
                    }
                } label: {
                    HStack(spacing: 4) { Text("API key"); keyBadge(keyCheck) }
                }
                keyStatus(keyCheck)
                Picker(L("模型", "Model"), selection: $translationModel) {
                    ForEach(provider.models, id: \.id) { Text($0.name).tag($0.id) }
                }
                .onChange(of: translationModel) { _, m in Settings.translationModel = m }
                Link(L("申請 \(provider.name) 的 API key", "Get a \(provider.name) API key"), destination: provider.keyPage)
                }
            } header: {
                Text(L("翻譯", "Translation"))
            } footer: {
                Text(cloudTranslation
                     ? L("翻譯選單會多出雲端選項，選了才會把逐字稿的文字送到 \(provider.name) 的伺服器，錄音檔不會上傳。雲端翻得比較自然，看得懂上下文。API key 存在這台 Mac 的鑰匙圈。",
                         "The translate menu gains cloud options; only when you pick one is transcript text sent to \(provider.name)’s servers. Audio is never uploaded. Cloud translation reads more naturally and understands context. The API key is stored in this Mac’s keychain.")
                     : L("關閉時只用 Apple 內建的本機翻譯，離線、免費，逐字稿不會離開這台 Mac；第一次用會請你下載語言。",
                         "When off, only Apple’s built-in on-device translation is used: offline, free, and transcripts never leave this Mac. You’ll be asked to download languages the first time."))
            }
            }

            Section {
                let _ = models.revision
                let busy = models.progress != nil
                Picker(L("在哪裡轉錄", "Transcribe on"), selection: $cloudTranscription) {
                    Text(L("這台 Mac", "This Mac")).tag(false)
                    Text(L("雲端", "Cloud")).tag(true)
                }
                .pickerStyle(.segmented)
                if cloudTranscription {
                    Picker(L("服務", "Service"), selection: $service) {
                        ForEach(TranscriptionService.allCases) { Text($0.name).tag($0) }
                    }
                    .onChange(of: service) { _, s in
                        Settings.transcriptionService = s
                        serviceModel = Settings.transcriptionModel
                        serviceKey = s.apiKey ?? ""
                        serviceCheck = .idle
                    }
                    Picker(L("模型", "Model"), selection: $serviceModel) {
                        ForEach(service.models, id: \.id) { Text($0.name).tag($0.id) }
                    }
                    .onChange(of: serviceModel) { _, m in Settings.transcriptionModel = m }
                    LabeledContent {
                        HStack {
                            SecureField("", text: $serviceKey, prompt: Text(L("貼上 API key", "Paste API key")))
                                .labelsHidden()
                                .onChange(of: serviceKey) { _, k in
                                    service.apiKey = k
                                    serviceCheck = .idle
                                }
                            Button(L("檢查", "Verify")) { verifyServiceKey() }
                                .disabled(serviceKey.trimmingCharacters(in: .whitespaces).isEmpty || serviceCheck == .checking)
                        }
                    } label: {
                        HStack(spacing: 4) { Text("API key"); keyBadge(serviceCheck) }
                    }
                    keyStatus(serviceCheck)
                    Link(L("申請 \(service.name) 的 API key", "Get a \(service.name) API key"), destination: service.keyPage)
                } else {
                // 語音模型選一個；沒在用的可以個別刪
                ForEach(Models.speech) { m in
                    let selected = m.id == Models.current.id
                    LabeledContent {
                        HStack {
                            if Models.installed(m) && !selected {
                                Button(L("刪除", "Delete")) { models.delete(m) }.disabled(busy)
                            }
                            status(m)
                        }
                    } label: {
                        Button { models.select(m) } label: {
                            Label {
                                VStack(alignment: .leading) {
                                    Text(m.name + (m.id == Models.recommended.id ? L("（建議）", " (Recommended)") : ""))
                                    Text("\(m.purpose) · \(size(m.size))").font(.caption).foregroundStyle(.secondary)
                                }
                            } icon: {
                                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                                    .foregroundStyle(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                            }
                        }
                        .buttonStyle(.plain)
                        .disabled(busy)
                    }
                }
                }
                // 分說話者不管在哪裡轉錄都在本機跑
                ForEach(Models.support) { m in
                    LabeledContent {
                        status(m)
                    } label: {
                        Text(m.name)
                        Text("\(m.purpose) · \(size(m.size))")
                    }
                }
                if let p = models.progress {
                    HStack {
                        ProgressView(value: p)
                        Text("\(Int(p * 100))%").monospacedDigit().frame(width: 44, alignment: .trailing)
                        Button(L("取消", "Cancel")) { models.cancel() }
                    }
                } else {
                    if !Models.ready {
                        let missing = Models.required.filter { !Models.installed($0) }.reduce(0) { $0 + $1.size }
                        Button(L("下載模型（\(size(missing))）", "Download Models (\(size(missing)))")) { models.downloadMissing() }
                            .buttonStyle(.borderedProminent)
                    }
                    if Models.installedSize > 0 {
                        Button(L("刪除所有模型（\(size(Models.installedSize))）", "Delete All Models (\(size(Models.installedSize)))"), role: .destructive) { confirmDelete = true }
                            .confirmationDialog(L("刪除所有模型？", "Delete all models?"), isPresented: $confirmDelete) {
                                Button(L("刪除", "Delete"), role: .destructive) { models.deleteAll() }
                            } message: {
                                Text(L("刪除後就不能轉逐字稿，要用時再下載。", "You won't be able to transcribe until you download them again."))
                            }
                    }
                }
                if let e = models.error {
                    Text(e).foregroundStyle(.red)
                }
            } header: {
                Text(L("轉錄", "Transcription"))
            } footer: {
                if cloudTranscription {
                    Label(L("錄音會上傳到 \(service.name) 轉成文字，分辨說話者還是在這台 Mac 上做。比本機快很多，也不用下載語音模型。API key 存在這台 Mac 的鑰匙圈。換服務不會動已經轉好的逐字稿，要的話重新轉錄。",
                            "Recordings are uploaded to \(service.name) to be transcribed; speaker detection still runs on this Mac. Much faster than on-device, and no speech model to download. The API key is stored in this Mac’s keychain. Switching doesn't change existing transcripts; re-transcribe if you want."),
                          systemImage: "cloud")
                } else {
                    Text(L("轉逐字稿和分辨說話者都在這台 Mac 上執行，錄音不會上傳。語音模型越大越準也越慢，「建議」是照這台 Mac 的記憶體挑的；換模型不會動已經轉好的逐字稿，要的話重新轉錄。模型目前佔 \(size(Models.installedSize))，存在「應用程式支援」資料夾。",
                           "Transcription and speaker detection run on this Mac; recordings are never uploaded. Larger speech models are more accurate but slower; “Recommended” is based on this Mac's memory. Switching models doesn't change existing transcripts; re-transcribe if you want. Models currently use \(size(Models.installedSize)) in the Application Support folder."))
                }
            }

            Section {
                LabeledContent(L("麥克風", "Microphone")) {
                    switch mic {
                    case .authorized: Text(L("已允許", "Allowed")).foregroundStyle(.secondary)
                    case .notDetermined:
                        Button(L("允許", "Allow")) { AVCaptureDevice.requestAccess(for: .audio) { _ in Task { @MainActor in mic = AVCaptureDevice.authorizationStatus(for: .audio) } } }
                    default:
                        Button(L("到系統設定開啟", "Open System Settings")) { openPrivacy("Privacy_Microphone") }
                    }
                }
                LabeledContent(L("瀏覽器的聲音", "Browser audio")) {
                    Button(L("到系統設定檢查", "Check in System Settings")) { openPrivacy("Privacy_AudioCapture") }
                }
                LabeledContent(L("讀會議分頁標題", "Read meeting tab title")) {
                    Button(L("到系統設定檢查", "Check in System Settings")) { openPrivacy("Privacy_Automation") }
                }
            } header: {
                Text(L("權限", "Permissions"))
            } footer: {
                Text(L("第一次錄音時系統會逐一詢問。瀏覽器的聲音在「螢幕與系統錄音」裡；分頁標題用來替錄音命名，沒有也能錄。",
                       "macOS asks for each one the first time you record. Browser audio is under “Screen & System Audio Recording”; the tab title is used to name recordings and is optional."))
            }
        }
        .formStyle(.grouped)
        .id(language)
        // 小螢幕放不下整頁，固定高度讓內容捲動
        .frame(width: 520, height: 640)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            mic = AVCaptureDevice.authorizationStatus(for: .audio)
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }

    /// 檢查結果放在「API key」標題右邊，不多佔一行
    @ViewBuilder private func keyBadge(_ check: KeyCheck) -> some View {
        switch check {
        case .idle: EmptyView()
        case .checking: ProgressView().controlSize(.small)
        case .ok: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).help(L("可以用", "Key works"))
        case .failed(let m): Image(systemName: "xmark.circle.fill").foregroundStyle(.red).help(m)
        }
    }

    /// 失敗的原因比較長，才另起一行
    @ViewBuilder private func keyStatus(_ check: KeyCheck) -> some View {
        if case .failed(let m) = check { Text(m).foregroundStyle(.red) }
    }

    private func verifyServiceKey() {
        serviceCheck = .checking
        let (s, key) = (service, serviceKey.trimmingCharacters(in: .whitespacesAndNewlines))
        Task {
            do {
                try await s.check(key: key)
                if service == s { serviceCheck = .ok }
            } catch {
                if service == s { serviceCheck = .failed("\(error)") }
            }
        }
    }

    private func verifyKey() {
        keyCheck = .checking
        let (p, key, model) = (provider, apiKey.trimmingCharacters(in: .whitespacesAndNewlines), translationModel)
        Task {
            do {
                try await Translator.check(p, key: key, model: model)
                if provider == p { keyCheck = .ok }
            } catch {
                if provider == p { keyCheck = .failed(error.localizedDescription) }
            }
        }
    }

    private func status(_ m: Models.Model) -> some View {
        Text(Models.installed(m) ? L("已下載", "Downloaded") : L("未下載", "Not downloaded"))
            // 只有現在要用的沒下載才標橘色
            .foregroundStyle(!Models.installed(m) && Models.required.contains { $0.id == m.id } ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
    }

    private func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func openPrivacy(_ anchor: String) {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!)
    }
}

/// 關於視窗：版本、開源元件與模型的授權（散布時必須附上）
@MainActor
enum About {
    static func show() {
        let licenses = Bundle.main.resourceURL!.appendingPathComponent("licenses")
        let credits = NSMutableAttributedString(string: L("錄音、轉逐字稿、分辨說話者都在這台 Mac 上完成。", "Recording, transcription and speaker detection all happen on this Mac.") + "\n\n" + L("使用的開源程式與模型：", "Open-source software and models:") + """

        whisper.cpp（MIT）、sherpa-onnx（Apache 2.0）、ONNX Runtime（MIT）
        Whisper（MIT，OpenAI）、Silero VAD（MIT）
        pyannote segmentation 3.0（MIT）、3D-Speaker CAM++（Apache 2.0）
        Lobe Icons（MIT）

        """, attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor])
        credits.append(NSAttributedString(string: L("授權全文", "Full license texts"), attributes: [.font: NSFont.systemFont(ofSize: 11), .link: licenses]))
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        credits.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: credits.length))
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
    }
}

/// 常用詞：一個詞一顆標籤，× 刪掉；輸入框按 Return 或打逗號、頓號就加進去。存起來還是一行一個
private struct VocabularyField: View {
    @Binding var text: String
    @State private var input = ""

    private var words: [String] {
        text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(words, id: \.self) { w in
                HStack(spacing: 3) {
                    Text(w)
                    Button { text = words.filter { $0 != w }.joined(separator: "\n") } label: {
                        Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help(L("移除", "Remove"))
                }
                .padding(.leading, 8)
                .padding(.trailing, 6)
                .padding(.vertical, 3)
                .background(.quaternary, in: Capsule())
            }
            TextField(L("加一個詞，按 Return", "Add a word, press Return"), text: $input)
                .textFieldStyle(.plain)
                .frame(minWidth: 150)
                .padding(.vertical, 3)
                .onSubmit { add(input) }
                .onChange(of: input) { _, v in
                    // 貼上一串或打了分隔符號：分隔符號前面的先加進去
                    let parts = v.split(separator: #/[,，、;；\n]/#, omittingEmptySubsequences: false)
                    guard parts.count > 1 else { return }
                    parts.dropLast().forEach { add(String($0)) }
                    input = String(parts.last ?? "")
                }
        }
        .padding(6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 6))
    }

    private func add(_ word: String) {
        let w = word.trimmingCharacters(in: .whitespaces)
        if !w.isEmpty, !words.contains(w) { text = (words + [w]).joined(separator: "\n") }
        input = ""
    }
}

/// 一行排不下就換行的橫排
private struct FlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, width: proposal.width ?? .infinity)
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0, height: rows.last.map { $0.y + $0.height } ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for row in arrange(subviews, width: bounds.width) {
            var x = bounds.minX
            for i in row.items {
                let size = subviews[i].sizeThatFits(.unspecified)
                subviews[i].place(at: CGPoint(x: x, y: bounds.minY + row.y + (row.height - size.height) / 2), proposal: .unspecified)
                x += size.width + spacing
            }
        }
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [(items: [Int], y: CGFloat, width: CGFloat, height: CGFloat)] {
        var rows: [(items: [Int], y: CGFloat, width: CGFloat, height: CGFloat)] = []
        var x: CGFloat = 0, y: CGFloat = 0, items: [Int] = [], height: CGFloat = 0
        for (i, v) in subviews.enumerated() {
            let size = v.sizeThatFits(.unspecified)
            if !items.isEmpty, x + size.width > width {
                rows.append((items, y, x - spacing, height))
                y += height + spacing
                x = 0; items = []; height = 0
            }
            items.append(i)
            x += size.width + spacing
            height = max(height, size.height)
        }
        if !items.isEmpty { rows.append((items, y, x - spacing, height)) }
        return rows
    }
}
