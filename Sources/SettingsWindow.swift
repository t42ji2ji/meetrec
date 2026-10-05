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
            w.title = "MeetRec 設定"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}

struct SettingsView: View {
    @ObservedObject private var models = Models.shared
    @State private var script = Settings.script
    @State private var askToRecord = Settings.askToRecord
    @State private var autoTranscribe = Settings.autoTranscribe
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var mic = AVCaptureDevice.authorizationStatus(for: .audio)
    @State private var confirmDelete = false

    var body: some View {
        Form {
            Section("一般") {
                Toggle("登入時自動啟動", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        if on { try? SMAppService.mainApp.register() } else { try? SMAppService.mainApp.unregister() }
                        launchAtLogin = SMAppService.mainApp.status == .enabled
                    }
                Toggle("瀏覽器開始用麥克風時，問要不要錄音", isOn: $askToRecord)
                    .onChange(of: askToRecord) { _, v in Settings.askToRecord = v }
                Toggle("錄完自動轉逐字稿", isOn: $autoTranscribe)
                    .onChange(of: autoTranscribe) { _, v in Settings.autoTranscribe = v }
                LabeledContent("錄音資料夾") {
                    HStack {
                        Text(Library.shared.folder.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button("打開") { NSWorkspace.shared.open(Library.shared.folder) }
                    }
                }
            }

            Section {
                Picker("中文字", selection: $script) {
                    ForEach(Settings.Script.allCases) { Text($0.label).tag($0) }
                }
                .onChange(of: script) { _, v in Settings.script = v }
            } header: {
                Text("逐字稿")
            } footer: {
                Text("轉錄時統一成這種字體；已經轉好的逐字稿不會改，要的話重新轉錄。")
            }

            Section {
                let _ = models.revision
                ForEach(Models.all) { m in
                    LabeledContent {
                        Text(Models.installed(m) ? "已下載" : "未下載")
                            .foregroundStyle(Models.installed(m) ? AnyShapeStyle(.secondary) : AnyShapeStyle(.orange))
                    } label: {
                        Text(m.name)
                        Text("\(m.purpose) · \(size(m.size))")
                    }
                }
                if let p = models.progress {
                    HStack {
                        ProgressView(value: p)
                        Text("\(Int(p * 100))%").monospacedDigit().frame(width: 44, alignment: .trailing)
                        Button("取消") { models.cancel() }
                    }
                } else if Models.ready {
                    Button("刪除模型（\(size(Models.totalSize))）", role: .destructive) { confirmDelete = true }
                        .confirmationDialog("刪除模型？", isPresented: $confirmDelete) {
                            Button("刪除", role: .destructive) { models.deleteAll() }
                        } message: {
                            Text("刪除後就不能轉逐字稿，要用時再下載（\(size(Models.totalSize))）。")
                        }
                } else {
                    Button("下載模型") { models.downloadAll() }
                        .buttonStyle(.borderedProminent)
                }
                if let e = models.error {
                    Text(e).foregroundStyle(.red)
                }
            } header: {
                Text("模型")
            } footer: {
                Text("轉逐字稿和分辨說話者都在這台 Mac 上執行，錄音不會上傳。模型共 \(size(Models.totalSize))，存在「應用程式支援」資料夾。")
            }

            Section {
                LabeledContent("麥克風") {
                    switch mic {
                    case .authorized: Text("已允許").foregroundStyle(.secondary)
                    case .notDetermined:
                        Button("允許") { AVCaptureDevice.requestAccess(for: .audio) { _ in Task { @MainActor in mic = AVCaptureDevice.authorizationStatus(for: .audio) } } }
                    default:
                        Button("到系統設定開啟") { openPrivacy("Privacy_Microphone") }
                    }
                }
                LabeledContent("瀏覽器的聲音") {
                    Button("到系統設定檢查") { openPrivacy("Privacy_AudioCapture") }
                }
                LabeledContent("讀會議分頁標題") {
                    Button("到系統設定檢查") { openPrivacy("Privacy_Automation") }
                }
            } header: {
                Text("權限")
            } footer: {
                Text("第一次錄音時系統會逐一詢問。瀏覽器的聲音在「螢幕與系統錄音」裡；分頁標題用來替錄音命名，沒有也能錄。")
            }
        }
        .formStyle(.grouped)
        // 小螢幕放不下整頁，固定高度讓內容捲動
        .frame(width: 520, height: 640)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            mic = AVCaptureDevice.authorizationStatus(for: .audio)
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
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
        let credits = NSMutableAttributedString(string: """
        錄音、轉逐字稿、分辨說話者都在這台 Mac 上完成。

        使用的開源程式與模型：
        whisper.cpp（MIT）、sherpa-onnx（Apache 2.0）、ONNX Runtime（MIT）
        Whisper large-v3-turbo（MIT，OpenAI）、Silero VAD（MIT）
        pyannote segmentation 3.0（MIT）、3D-Speaker CAM++（Apache 2.0）

        """, attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor])
        credits.append(NSAttributedString(string: "授權全文", attributes: [.font: NSFont.systemFont(ofSize: 11), .link: licenses]))
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        credits.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: credits.length))
        NSApp.activate()
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
    }
}
