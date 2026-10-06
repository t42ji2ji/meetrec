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
            let w = NSWindow(contentViewController: NSHostingController(rootView: SettingsView()))
            w.title = L("MeetRec 設定", "MeetRec Settings")
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            w.center()
            window = w
            NotificationCenter.default.addObserver(forName: Settings.languageChanged, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { w.title = L("MeetRec 設定", "MeetRec Settings") }
            }
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}

struct SettingsView: View {
    @ObservedObject private var models = Models.shared
    @AppStorage("language") private var language = Settings.Language.system
    @State private var transcriptLanguage = Settings.transcriptLanguage
    @State private var script = Settings.script
    @State private var askToRecord = Settings.askToRecord
    @State private var autoTranscribe = Settings.autoTranscribe
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var mic = AVCaptureDevice.authorizationStatus(for: .audio)
    @State private var confirmDelete = false

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
            } header: {
                Text(L("逐字稿", "Transcript"))
            } footer: {
                Text(L("自動偵測聽每份錄音的開頭判斷語言，中英夾雜的會議通常判成中文、英文詞照樣保留；判錯就指定語言再重新轉錄。中文字統一成選的字體。改設定不會動已經轉好的逐字稿。",
                       "Automatic detection listens to the start of each recording; mixed Chinese–English meetings usually come out as Chinese with English words kept. If it guesses wrong, pick the language and re-transcribe. Chinese text is converted to the chosen script. Changing these doesn't touch existing transcripts."))
            }

            Section {
                let _ = models.revision
                let busy = models.progress != nil
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
                Text(L("模型", "Models"))
            } footer: {
                Text(L("轉逐字稿和分辨說話者都在這台 Mac 上執行，錄音不會上傳。語音模型越大越準也越慢，「建議」是照這台 Mac 的記憶體挑的；換模型不會動已經轉好的逐字稿，要的話重新轉錄。模型目前佔 \(size(Models.installedSize))，存在「應用程式支援」資料夾。",
                       "Transcription and speaker detection run on this Mac; recordings are never uploaded. Larger speech models are more accurate but slower; “Recommended” is based on this Mac's memory. Switching models doesn't change existing transcripts; re-transcribe if you want. Models currently use \(size(Models.installedSize)) in the Application Support folder."))
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
        NSApp.activate()
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
    }
}
