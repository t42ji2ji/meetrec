import AppKit
import SwiftUI

/// 匯入：拖檔案、選檔案，或貼 YouTube／Bilibili／X／Podcast 等網址
struct ImportSheet: View {
    let chooseFiles: () -> Void
    /// 回傳有沒有收（只收聲音和影片）
    let dropFiles: ([URL]) -> Bool
    let importLink: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var link = ""
    @State private var dropping = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                Text(L("匯入", "Import")).font(.title2.weight(.semibold))
                Text(L("匯入後會自動轉逐字稿", "Everything you import is transcribed automatically")).foregroundStyle(.secondary)
            }
            dropZone
            HStack(spacing: 10) {
                VStack { Divider() }
                Text(L("或從網址", "or from a link")).font(.callout).foregroundStyle(.secondary)
                VStack { Divider() }
            }
            linkField
            HStack {
                Spacer()
                Button(L("取消", "Cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(L("下載並匯入", "Download & Import")) { submit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!valid)
            }
        }
        .padding(24)
        .frame(width: 480)
        .onAppear {
            // 剪貼簿裡剛好是網址就先填好
            if let s = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines), s.hasPrefix("http"), !s.contains(" ") { link = s }
        }
    }

    private var dropZone: some View {
        VStack(spacing: 10) {
            Image(systemName: "waveform.badge.plus")
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(dropping ? Color.accentColor : .secondary)
            Text(L("把音檔或影片拖到這裡", "Drop audio or video files here")).font(.headline)
            Button(L("選擇檔案…", "Choose Files…")) {
                dismiss()
                // 等 sheet 收起來再開檔案面板
                DispatchQueue.main.async(execute: chooseFiles)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .background(RoundedRectangle(cornerRadius: 12).fill(dropping ? Color.accentColor.opacity(0.08) : Color.primary.opacity(0.03)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(dropping ? Color.accentColor : Color.secondary.opacity(0.4), style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])))
        .dropDestination(for: URL.self) { urls, _ in
            guard dropFiles(urls) else { return false }
            dismiss()
            return true
        } isTargeted: { dropping = $0 }
        .animation(.easeOut(duration: 0.15), value: dropping)
    }

    private var linkField: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "link").foregroundStyle(.secondary)
                TextField(L("貼上網址", "Paste a link"), text: $link)
                    .textFieldStyle(.plain)
                    .onSubmit(submit)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.secondary.opacity(0.3)))
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: 4), alignment: .leading, spacing: 8) {
                ForEach(LinkSource.allCases, id: \.self) { s in
                    // 認出是哪個平台就只亮那個
                    SourceBadge(source: s).opacity(detected == nil || detected == s ? 1 : 0.3)
                }
            }
            .animation(.easeOut(duration: 0.15), value: detected)
            Text(L("其他影音網站的網址也可以試試。Spotify 的音檔有版權保護，會改從 Apple Podcasts 下載同一集；Spotify 獨家節目沒辦法匯入。",
                   "Links from other video and audio sites often work, too. Spotify audio is copy-protected, so the same episode is downloaded from Apple Podcasts instead. Spotify exclusives can’t be imported."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var url: URL? {
        let s = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let u = URL(string: s), u.scheme?.hasPrefix("http") == true, u.host != nil else { return nil }
        return u
    }

    private var valid: Bool { url != nil }
    private var detected: LinkSource? { url.flatMap(LinkSource.init) }

    private func submit() {
        guard valid else { return }
        importLink(link)
        dismiss()
    }
}

/// 實際用 yt-dlp 抓過、AVFoundation 讀得了的平台。Vimeo、Instagram、抖音要登入，TED、Niconico 抓不到，不列
enum LinkSource: CaseIterable {
    case youtube, bilibili, x, tiktok, applepodcasts, spotify, soundcloud, facebook, twitch, dailymotion

    /// 工具列放不下全部，只放這幾個
    static let toolbar: [LinkSource] = [.youtube, .bilibili, .x, .applepodcasts, .spotify]

    init?(_ url: URL) {
        let host = url.host?.lowercased() ?? ""
        func on(_ domains: String...) -> Bool { domains.contains { host == $0 || host.hasSuffix("." + $0) } }
        if on("youtube.com", "youtu.be") { self = .youtube }
        else if on("bilibili.com", "b23.tv") { self = .bilibili }
        else if on("x.com", "twitter.com") { self = .x }
        else if on("tiktok.com") { self = .tiktok }
        else if host == "podcasts.apple.com" { self = .applepodcasts }
        else if on("spotify.com") { self = .spotify }
        else if on("soundcloud.com") { self = .soundcloud }
        else if on("facebook.com", "fb.watch") { self = .facebook }
        else if on("twitch.tv") { self = .twitch }
        else if on("dailymotion.com", "dai.ly") { self = .dailymotion }
        else { return nil }
    }

    var name: String {
        switch self {
        case .youtube: "YouTube"
        case .bilibili: "Bilibili"
        case .x: "X"
        case .tiktok: "TikTok"
        case .applepodcasts: "Podcasts"
        case .spotify: "Spotify"
        case .soundcloud: "SoundCloud"
        case .facebook: "Facebook"
        case .twitch: "Twitch"
        case .dailymotion: "Dailymotion"
        }
    }

    /// X、TikTok、Dailymotion 的 logo 是黑色，用 primary 才跟得上深色模式
    var color: Color {
        switch self {
        case .youtube: Color(red: 1, green: 0, blue: 0)
        case .bilibili: Color(red: 0, green: 0.63, blue: 0.84)
        case .applepodcasts: Color(red: 0.6, green: 0.2, blue: 0.8)
        case .spotify: Color(red: 0.12, green: 0.84, blue: 0.38)
        case .soundcloud: Color(red: 1, green: 0.33, blue: 0)
        case .facebook: Color(red: 0.03, green: 0.4, blue: 1)
        case .twitch: Color(red: 0.57, green: 0.27, blue: 1)
        case .x, .tiktok, .dailymotion: .primary
        }
    }

    var mark: some View { LogoMark(name: "\(self)", color: color, size: 16) }
}

/// Resources/icons 裡的品牌 logo。YouTube 的三角形、Podcast 的圖案是鏤空的，底下墊白色才像原本的 logo
struct LogoMark: View {
    let name: String
    let color: Color
    let size: CGFloat

    var body: some View {
        Image(nsImage: NSImage(contentsOf: Bundle.main.resourceURL!.appendingPathComponent("icons/\(name).svg")) ?? NSImage())
            .resizable()
            .renderingMode(.template)
            .foregroundStyle(color)
            .frame(width: size, height: size)
            .background {
                switch name {
                case "youtube": Rectangle().fill(.white).frame(width: size * 0.45, height: size * 0.4)
                case "applepodcasts": RoundedRectangle(cornerRadius: size * 0.2).fill(.white).padding(size * 0.1)
                default: EmptyView()
                }
            }
    }
}

private struct SourceBadge: View {
    let source: LinkSource

    var body: some View {
        HStack(spacing: 6) {
            source.mark
            Text(source.name).font(.callout)
        }
    }
}
