import AppKit
import AVFoundation
import SwiftUI

/// 第一次打開：介紹、選在哪裡轉錄（建議 Groq）、麥克風、開始用。走完才記下來，中途關掉下次還會出現
@MainActor
final class Onboarding {
    static let shared = Onboarding()
    private var window: NSWindow?

    /// 開發時預覽用：`open MeetRec.app --args -forceOnboarding YES`
    static var forced: Bool { UserDefaults.standard.bool(forKey: "forceOnboarding") }

    static var done: Bool {
        get { UserDefaults.standard.bool(forKey: "onboarded") }
        set { UserDefaults.standard.set(newValue, forKey: "onboarded") }
    }

    func show() {
        if window == nil {
            let host = NSHostingController(rootView: OnboardingView { [weak self] in self?.finish() })
            // 大小由下面固定，不讓 SwiftUI 排版完再把視窗撐高 32pt（標題列），置中才準
            host.sizingOptions = []
            let w = EditingWindow(contentViewController: host)
            w.title = L("歡迎使用 MeetRec", "Welcome to MeetRec")
            // 不要視窗的樣子：沒有標題列、沒有紅綠燈，整片都是內容，拖哪裡都能移動
            w.styleMask = [.titled, .fullSizeContentView]
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isMovableByWindowBackground = true
            w.backgroundColor = .black
            w.isReleasedWhenClosed = false
            // 不用 center()：它會故意偏上
            w.setContentSize(NSSize(width: 960, height: 640))
            if let screen = NSScreen.main?.visibleFrame {
                w.setFrameOrigin(NSPoint(x: screen.midX - 480, y: screen.midY - 320))
            }
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
    }

    private func finish() {
        Self.done = true
        window?.close()
        window = nil
        Dashboard.shared.show()
    }
}

/// 這台 Mac 轉一小時的會議大概要幾分鐘。基準是 M1 Pro 實測（10 分鐘的中文會議錄音）：
/// whisper small 33 秒、turbo 53 秒（跑 GPU）；分辨說話者 59 秒（跑 CPU，跟 whisper 同時跑）。
/// 雲端轉錄時 whisper 那段交給 Groq，但分辨說話者還是在本機，所以兩邊差得沒想像中多。其他晶片照規模和世代粗估，給一個範圍
enum Speed {
    nonisolated static func local(_ m: Models.Model) -> ClosedRange<Int> {
        range(max(whisper(m) / gpuFactor, diarize))
    }

    /// 上傳加 Groq 處理一小時約半分鐘
    nonisolated static var cloud: ClosedRange<Int> { range(diarize + 0.5) }

    /// GPU 弱的 Mac 本機 whisper 比分辨說話者慢，雲端才真的比較快
    nonisolated static var cloudIsFaster: Bool { max(whisper(Models.current) / gpuFactor, diarize) > (diarize + 0.5) * 1.3 }

    private nonisolated static func whisper(_ m: Models.Model) -> Double {
        m.file.contains("small") ? 3.3 : m.file.contains("turbo") ? 5.3 : 10.6
    }

    private nonisolated static var diarize: Double { 5.9 / cpuFactor }

    private nonisolated static func range(_ t: Double) -> ClosedRange<Int> {
        max(1, Int((t * 0.75).rounded()))...max(2, Int((t * 1.3).rounded()))
    }

    private nonisolated static var chip: String {
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        var buf = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("machdep.cpu.brand_string", &buf, &size, nil, 0)
        return String(cString: buf)
    }

    private nonisolated static var generation: Double {
        chip.contains("M1") ? 1 : chip.contains("M2") ? 1.15 : chip.contains("M3") ? 1.35 : chip.contains("M4") ? 1.6 : 1.9
    }

    /// 相對 M1 Pro：GPU 核心數差很多
    private nonisolated static var gpuFactor: Double {
        generation * (chip.contains("Ultra") ? 2.8 : chip.contains("Max") ? 1.7 : chip.contains("Pro") ? 1 : 0.5)
    }

    /// 分辨說話者固定用 4 條執行緒，各級晶片差不多，只有世代差
    private nonisolated static var cpuFactor: Double {
        (1 + (generation - 1) * 0.6) * (chip.contains("Pro") || chip.contains("Max") || chip.contains("Ultra") ? 1 : 0.9)
    }
}

/// 跟官網同一套：深色底、大字、四個說話者的顏色
private enum Palette {
    static let bg = Color(red: 0.07, green: 0.07, blue: 0.075)
    static let surface = Color.white.opacity(0.06)
    static let line = Color.white.opacity(0.12)
    static let muted = Color.white.opacity(0.6)
    static let speakers = [Color(red: 0.36, green: 0.61, blue: 1), Color(red: 0.96, green: 0.6, blue: 0.31),
                           Color(red: 0.3, green: 0.75, blue: 0.45), Color(red: 0.82, green: 0.47, blue: 0.9)]
}

private struct OnboardingView: View {
    let finish: () -> Void
    @ObservedObject private var models = Models.shared
    @State private var step = 0
    @State private var forward = true
    /// 按了「稍後設定」：不存選擇、不下載語音模型
    @State private var later = false
    @State private var cloud = true
    @State private var key = TranscriptionService.groq.apiKey ?? ""
    @State private var check: Check = .idle
    @State private var mic = AVCaptureDevice.authorizationStatus(for: .audio)
    @State private var browserAudio = Permissions.browserAudio
    /// 讀分頁標題：裝了的瀏覽器全部允許才算好
    @State private var tabs: Permissions.State = .unknown
    @State private var askingTabs = false

    private enum Check: Equatable { case idle, checking, ok, failed(String) }

    var body: some View {
        ZStack(alignment: .bottom) {
            Palette.bg.ignoresSafeArea()
            Group {
                switch step {
                case 0: welcome
                case 1: transcribe
                case 2: microphone
                default: ready
                }
            }
            .id(step)
            .transition(.asymmetric(insertion: .move(edge: forward ? .trailing : .leading).combined(with: .opacity),
                                    removal: .move(edge: forward ? .leading : .trailing).combined(with: .opacity)))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.horizontal, 64)
            .padding(.top, 96)
            .padding(.bottom, 110)
            footer
        }
        .frame(width: 960, height: 640)
        // 標題列是透明的，不讓 SwiftUI 再替它多留 32pt：視窗才會剛好 960×640，置中算得準
        .ignoresSafeArea()
        .preferredColorScheme(.dark)
        .tint(Palette.speakers[0])
        .onAppear {
            // 分辨說話者的模型（幾十 MB）不管選哪邊都要，先下載；在哪裡轉錄等使用者選了才存
            models.downloadMissing(only: Models.support)
            if !key.isEmpty { verify() }
            checkTabs(ask: false)
        }
        .onChange(of: models.progress == nil) { _, idle in
            // 前一批下載完，選了本機的話接著下載語音模型
            if idle, step >= 2, !later, !Models.ready, models.error == nil { models.downloadMissing() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            mic = AVCaptureDevice.authorizationStatus(for: .audio)
            browserAudio = Permissions.browserAudio
            checkTabs(ask: false)
        }
    }

    private var footer: some View {
        HStack(spacing: 16) {
            // 進度：四段說話者顏色，走過的亮起來
            HStack(spacing: 6) {
                ForEach(0..<4) { i in
                    Capsule().fill(i <= step ? Palette.speakers[i] : Palette.line)
                        .frame(width: i == step ? 36 : 18, height: 6)
                }
            }
            .animation(.spring(duration: 0.4), value: step)
            if step == 1 {
                // 還沒有 key 也不想用本機：先跳過，之後在設定裡選。放左邊、字小一點，不跟「繼續」搶
                Button(L("稍後設定", "Set Up Later")) { go(1, save: false) }
                    .buttonStyle(.plain)
                    .foregroundStyle(Palette.muted)
                    .font(.system(size: 13))
                    .padding(.leading, 12)
            }
            Spacer()
            if step > 0 {
                Button(L("上一步", "Back")) { go(-1) }
                    .buttonStyle(.plain)
                    .foregroundStyle(Palette.muted)
                    .font(.system(size: 15, weight: .medium))
                    .keyboardShortcut(.cancelAction)
            }
            let blocked = step == 1 && cloud && check != .ok
            Button { step < 3 ? go(1) : finish() } label: {
                Text(step < 3 ? L("繼續", "Continue") : L("開始使用", "Get Started"))
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 26)
                    .padding(.vertical, 12)
                    .background(Capsule().fill(.white))
                    .opacity(blocked ? 0.35 : 1)
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .keyboardShortcut(.defaultAction)
            .disabled(blocked)
        }
        .padding(.horizontal, 64)
        .padding(.bottom, 40)
    }

    private func go(_ delta: Int, save: Bool = true) {
        if step == 1, delta > 0 { later = !save }
        if step == 1, delta > 0, save {
            Settings.cloudTranscription = cloud
            if cloud { Settings.transcriptionService = .groq } else { Settings.speechModel = Models.recommended.file }
            models.downloadMissing()
        }
        forward = delta > 0
        withAnimation(.spring(duration: 0.45)) { step += delta }
    }

    private func headline(_ text: String) -> some View {
        Text(text).font(.system(size: 52, weight: .heavy)).tracking(-1.5).foregroundStyle(.white)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: 1. 介紹

    private var welcome: some View {
        HStack(alignment: .top, spacing: 56) {
            VStack(alignment: .leading, spacing: 28) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 64, height: 64)
                VStack(alignment: .leading, spacing: 10) {
                    headline(L("知道誰說了什麼。", "Know who\nsaid what."))
                    // 底線是四個人的發言比例
                    HStack(spacing: 0) {
                        ForEach(Array([0.35, 0.21, 0.19, 0.25].enumerated()), id: \.offset) { i, w in
                            Palette.speakers[i].frame(width: 260 * w, height: 6)
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 14) {
                    point(L("錄下會議，每一句都標好說話者", "Record a meeting, every line labeled by speaker"))
                    point(L("貼 YouTube、Bilibili、X、Podcast 網址也能轉", "Paste a YouTube, Bilibili, X or podcast link, too"), brands: ["youtube", "bilibili", "x", "applepodcasts"])
                    point(L("按 ⌘E 請 Claude Code 或 Codex 整理待辦", "Press ⌘E for action items from Claude Code or Codex"), brands: ["claude", "codex"])
                }
            }
            .frame(width: 380, alignment: .leading)
            DemoTranscript()
        }
    }

    private func point(_ text: String, brands: [String] = []) -> some View {
        HStack(spacing: 12) {
            Circle().fill(Palette.muted).frame(width: 5, height: 5)
            Text(text).font(.system(size: 17)).foregroundStyle(.white.opacity(0.85))
            HStack(spacing: 6) { ForEach(brands, id: \.self) { BrandMark(name: $0, size: 16) } }
        }
    }

    // MARK: 2. 在哪裡轉錄

    private var transcribe: some View {
        let local = Models.recommended
        let l = Speed.local(local)
        return VStack(alignment: .leading, spacing: 28) {
            VStack(alignment: .leading, spacing: 10) {
                headline(L("在哪裡轉逐字稿？", "Where should we transcribe?"))
                Text(L("選 Groq 會把錄音上傳轉文字。之後隨時可以在設定裡改。", "Groq uploads your audio to transcribe it. You can change this any time in Settings.")).font(.system(size: 17)).foregroundStyle(Palette.muted)
            }
            HStack(alignment: .top, spacing: 20) {
                card(selected: cloud, color: Palette.speakers[0], icon: AnyView(BrandMark(name: "groq", size: 22)), title: L("Groq 雲端", "Groq cloud"), badge: L("建議", "Recommended"), lines: [
                    L("最準、不佔電腦效能", "Most accurate, no load on your Mac") + (Speed.cloudIsFaster ? L("，也比較快", ", and faster") : ""),
                    L("每天免費約 8 小時", "About 8 free hours a day"),
                ]) {
                    cloud = true
                } extra: {
                    if cloud { keyField.transition(.opacity) }
                }
                card(selected: !cloud, color: Palette.speakers[2], icon: AnyView(Image(systemName: "laptopcomputer").font(.system(size: 20, weight: .semibold)).foregroundStyle(Palette.speakers[2])), title: L("在這台 Mac 上", "On this Mac"), badge: nil, lines: [
                    L("離線，錄音不離開這台 Mac", "Offline; audio stays on this Mac"),
                    L("下載 \(size(local.size))，一小時會議約 \(l.lowerBound)–\(l.upperBound) 分鐘", "\(size(local.size)) download, \(l.lowerBound)–\(l.upperBound) min per meeting hour"),
                ]) {
                    cloud = false
                } extra: { EmptyView() }
            }
        }
    }

    private func card<Extra: View>(selected: Bool, color: Color, icon: AnyView, title: String, badge: String?, lines: [String],
                                   pick: @escaping () -> Void, @ViewBuilder extra: () -> Extra) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                icon
                Text(title).font(.system(size: 22, weight: .bold)).foregroundStyle(.white)
                if let badge {
                    Text(badge).font(.system(size: 12, weight: .bold)).foregroundStyle(.black)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Capsule().fill(color))
                }
                Spacer()
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 22)).foregroundStyle(selected ? color : Palette.line)
            }
            VStack(alignment: .leading, spacing: 7) {
                ForEach(lines, id: \.self) { Text($0).font(.system(size: 15)).foregroundStyle(.white.opacity(0.75)) }
            }
            extra()
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(selected ? color.opacity(0.12) : Palette.surface))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(selected ? color : Palette.line, lineWidth: selected ? 2 : 1))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture(perform: pick)
        .animation(.easeOut(duration: 0.2), value: selected)
    }

    private var keyField: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                SecureField("", text: $key, prompt: Text(L("貼上 Groq API key", "Paste your Groq API key")))
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .padding(.horizontal, 12).padding(.vertical, 9)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.black.opacity(0.35)))
                    .onChange(of: key) { _, k in
                        TranscriptionService.groq.apiKey = k
                        check = .idle
                        // 貼上就檢查，不用再按
                        if k.trimmingCharacters(in: .whitespaces).count > 20 { verify() }
                    }
                switch check {
                case .checking: ProgressView().controlSize(.small)
                case .ok: Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.speakers[2])
                case .failed: Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                case .idle: EmptyView()
                }
            }
            if case .failed(let m) = check {
                Text(m).font(.system(size: 13)).foregroundStyle(.red).lineLimit(2)
            }
            Link(L("免費申請 Groq API key →", "Get a free Groq API key →"), destination: TranscriptionService.groq.keyPage)
                .font(.system(size: 14, weight: .semibold))
        }
        .padding(.top, 4)
    }

    private func verify() {
        let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
        check = .checking
        Task {
            do {
                try await TranscriptionService.groq.check(key: k)
                if key.trimmingCharacters(in: .whitespacesAndNewlines) == k { check = .ok }
            } catch {
                if key.trimmingCharacters(in: .whitespacesAndNewlines) == k { check = .failed("\(error)") }
            }
        }
    }

    // MARK: 3. 麥克風

    private var microphone: some View {
        HStack(alignment: .center, spacing: 56) {
            VStack(alignment: .leading, spacing: 22) {
                headline(L("讓 MeetRec\n聽得到你。", "Let MeetRec\nhear you."))
                Text(L("你的聲音和會議裡其他人分開收，逐字稿才分得出哪句是你說的。",
                       "Your voice is recorded apart from everyone else in the call, so the transcript knows which lines are yours."))
                    .font(.system(size: 17)).foregroundStyle(Palette.muted).frame(maxWidth: 440, alignment: .leading)
                VStack(alignment: .leading, spacing: 14) {
                    permission(L("麥克風", "Microphone"), L("收你的聲音", "Records your voice"),
                               mic == .authorized ? .granted : mic == .notDetermined ? .unknown : .denied, settings: "Privacy_Microphone") {
                        AVCaptureDevice.requestAccess(for: .audio) { _ in
                            Task { @MainActor in mic = AVCaptureDevice.authorizationStatus(for: .audio) }
                        }
                    }
                    permission(L("瀏覽器的聲音", "Browser audio"), L("收會議裡其他人的聲音", "Records everyone else in the call"),
                               browserAudio, settings: "Privacy_AudioCapture") {
                        Permissions.requestBrowserAudio { Task { @MainActor in browserAudio = Permissions.browserAudio } }
                    }
                    if !Permissions.tabBrowsers.isEmpty {
                        permission(L("讀會議分頁標題", "Meeting tab titles"),
                                   L("用會議名稱替錄音命名（\(Permissions.tabBrowsers.map(\.name).joined(separator: "、"))）",
                                     "Names recordings after the meeting (\(Permissions.tabBrowsers.map(\.name).joined(separator: ", ")))"),
                                   tabs, settings: "Privacy_Automation", busy: askingTabs) { checkTabs(ask: true) }
                    }
                }
                .frame(maxWidth: 460)
                .padding(.top, 6)
            }
            Spacer()
            // 兩個聲道：左邊是你，右邊是其他人
            HStack(spacing: 28) {
                Bars(color: Palette.speakers[0], label: L("你", "You"))
                Bars(color: Palette.speakers[1], label: L("其他人", "Everyone else"))
            }
        }
        .frame(maxHeight: .infinity)
    }

    /// 一個權限一行：允許了打勾；沒問過給「允許」；拒絕過只能到系統設定改
    private func permission(_ title: String, _ detail: String, _ state: Permissions.State, settings: String, busy: Bool = false, allow: @escaping () -> Void) -> some View {
        HStack(spacing: 14) {
            Image(systemName: state == .granted ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 22)).foregroundStyle(state == .granted ? Palette.speakers[2] : Palette.muted)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
                Text(detail).font(.system(size: 13)).foregroundStyle(Palette.muted)
            }
            Spacer()
            if busy {
                ProgressView().controlSize(.small)
            } else if state == .denied {
                Button(L("到系統設定開啟", "Open System Settings")) {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(settings)")!)
                }
            } else if state == .unknown {
                Button(L("允許", "Allow"), action: allow).buttonStyle(.borderedProminent)
            }
        }
    }

    /// 每個裝了的瀏覽器都問；ask 的時候沒開的瀏覽器會在背景打開
    private func checkTabs(ask: Bool) {
        if ask { askingTabs = true }
        DispatchQueue.global().async {
            let states = Permissions.tabBrowsers.map { Permissions.automation($0, ask: ask) }
            let result: Permissions.State = states.contains(.denied) ? .denied : states.allSatisfy { $0 == .granted } ? .granted : .unknown
            DispatchQueue.main.async {
                tabs = result
                askingTabs = false
            }
        }
    }

    private func pill(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
                .padding(.horizontal, 22).padding(.vertical, 11)
                .background(Capsule().fill(Palette.speakers[0]))
        }
        .buttonStyle(.plain)
    }

    // MARK: 4. 完成

    private var ready: some View {
        let _ = models.revision
        return VStack(alignment: .leading, spacing: 30) {
            VStack(alignment: .leading, spacing: 14) {
                headline(L("準備好了。", "You're all set."))
                HStack(spacing: 10) {
                    Text(L("開會時 MeetRec 會自己跳出來問要不要錄，不用記得按。", "When a meeting starts, MeetRec pops up and asks to record. Nothing to remember."))
                        .font(.system(size: 17)).foregroundStyle(.white.opacity(0.85))
                    ForEach(["googlemeet", "microsoftteams", "slack"], id: \.self) { BrandMark(name: $0, size: 18) }
                }
            }
            Group {
                if let p = models.progress {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(L("正在下載模型… \(Int(p * 100))%", "Downloading models… \(Int(p * 100))%"))
                            .font(.system(size: 15, weight: .medium).monospacedDigit()).foregroundStyle(.white)
                        ProgressView(value: p).frame(maxWidth: 420)
                        Text(L("可以先開始用，下載完才會轉逐字稿。", "You can start now; transcription begins once the download finishes."))
                            .font(.system(size: 14)).foregroundStyle(Palette.muted)
                    }
                } else if later {
                    Label(L("還沒選在哪裡轉錄，之後到「設定 › 轉錄」選就好。", "Transcription isn't set up yet. Choose in Settings › Transcription when you're ready."), systemImage: "clock")
                        .font(.system(size: 15, weight: .medium)).foregroundStyle(Palette.muted)
                } else if let e = models.error {
                    HStack {
                        Text(e).foregroundStyle(.red)
                        Button(L("重試", "Retry")) { models.downloadMissing() }
                    }
                } else if Models.ready {
                    Label(L("模型已下載", "Models downloaded"), systemImage: "checkmark.circle.fill")
                        .font(.system(size: 15, weight: .semibold)).foregroundStyle(Palette.speakers[2])
                }
            }
            HStack(alignment: .top, spacing: 20) {
                tip("record.circle", Palette.speakers[0], L("自動跳出來", "It pops up on its own"),
                    L("瀏覽器或 Slack 開始用麥克風時就會問。也可以從選單列手動開始。", "It asks when your browser or Slack starts using the mic. You can also start from the menu bar."),
                    brands: ["googlemeet", "microsoftteams", "slack"])
                tip("square.and.arrow.down", Palette.speakers[1], L("匯入現有的錄音", "Import what you have"),
                    L("把音檔拖進來，或貼上 YouTube、Bilibili、X、Podcast 網址。", "Drag in audio files, or paste a YouTube, Bilibili, X or podcast link."),
                    brands: ["youtube", "bilibili", "x", "applepodcasts"])
                tip("sparkles", Palette.speakers[3], L("問你的 agent", "Ask your agent"),
                    L("打開一場會議按 ⌘E，請 Claude Code 或 Codex 整理。", "Open a meeting and press ⌘E to ask Claude Code or Codex."),
                    brands: ["claude", "codex"])
            }
        }
        .onAppear { if !later, !Models.ready, models.progress == nil, models.error == nil { models.downloadMissing() } }
    }

    private func tip(_ symbol: String, _ color: Color, _ title: String, _ detail: String, brands: [String]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: symbol).font(.system(size: 24, weight: .semibold)).foregroundStyle(color)
                Spacer()
                ForEach(brands, id: \.self) { BrandMark(name: $0, size: 18) }
            }
            Text(title).font(.system(size: 17, weight: .bold)).foregroundStyle(.white)
            Text(detail).font(.system(size: 14)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Palette.surface))
    }

    private func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

/// 介紹頁右邊：一段逐字稿，說話者的名字一個個亮起來
private struct DemoTranscript: View {
    @State private var shown = 0
    private let lines: [(String, Int, String)] = [
        ("Me", 0, L("好，我們把上線計畫定下來。", "Let's lock the plan for the launch.")),
        ("Sarah", 1, L("Beta 週五結束，大概 300 位測試者。", "The beta wrapped up Friday. About 300 testers.")),
        ("Daniel", 2, L("匯出的 bug 這週修好。", "We can fix the export bug this week.")),
        ("Priya", 3, L("這會影響多少使用者？", "How many users does that affect?")),
        ("Daniel", 2, L("大約 4%。", "Roughly 4%.")),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Circle().fill(.red).frame(width: 9, height: 9)
                Text("REC").font(.system(size: 12, weight: .semibold, design: .monospaced)).foregroundStyle(.red)
                Text("Launch Planning Sync").font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
            }
            .padding(.bottom, 16)
            ForEach(Array(lines.enumerated()), id: \.offset) { i, l in
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(i < shown ? l.0 : "???")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(i < shown ? Palette.speakers[l.1] : Palette.muted)
                        .padding(.horizontal, 9).padding(.vertical, 4)
                        .background(Capsule().fill(i < shown ? Palette.speakers[l.1].opacity(0.18) : Palette.surface))
                        .frame(width: 70, alignment: .leading)
                    Text(l.2).font(.system(size: 15)).foregroundStyle(.white.opacity(i < shown ? 0.9 : 0.4))
                }
                .padding(.vertical, 9)
                .animation(.spring(duration: 0.35), value: shown)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Palette.surface))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Palette.line))
        .task {
            try? await Task.sleep(for: .seconds(0.6))
            for i in 1...lines.count {
                shown = i
                try? await Task.sleep(for: .seconds(0.45))
            }
        }
    }
}

/// 麥克風頁：一個聲道的音量條在跳
private struct Bars: View {
    let color: Color
    let label: String

    var body: some View {
        VStack(spacing: 14) {
            TimelineView(.animation) { t in
                let s = t.date.timeIntervalSinceReferenceDate
                HStack(alignment: .center, spacing: 5) {
                    ForEach(0..<7) { i in
                        let h = 30 + 90 * abs(sin(s * (2.1 + Double(i) * 0.37) + Double(i)))
                        Capsule().fill(color).frame(width: 9, height: h)
                    }
                }
                .frame(height: 130)
            }
            Text(label).font(.system(size: 14, weight: .semibold)).foregroundStyle(Palette.muted)
        }
    }
}

/// 品牌 logo（Resources/icons），用各自的品牌色；Slack 官方紫在深色底上看不到，用它 logo 裡的桃紅；Codex 是 OpenAI 黑，換白
private struct BrandMark: View {
    let name: String
    var size: CGFloat

    private static let colors: [String: Color] = [
        "groq": Color(red: 0.96, green: 0.31, blue: 0.21),
        "googlemeet": Color(red: 0, green: 0.54, blue: 0.48),
        "microsoftteams": Color(red: 0.38, green: 0.39, blue: 0.65),
        "slack": Color(red: 0.88, green: 0.12, blue: 0.35),
        "youtube": Color(red: 1, green: 0, blue: 0),
        "bilibili": Color(red: 0, green: 0.63, blue: 0.84),
        "applepodcasts": Color(red: 0.6, green: 0.2, blue: 0.8),
        "spotify": Color(red: 0.12, green: 0.84, blue: 0.38),
        "claude": Color(red: 0.85, green: 0.47, blue: 0.34),
        "codex": .white,
    ]

    var body: some View {
        LogoMark(name: name, color: Self.colors[name] ?? .white, size: size)
    }
}
