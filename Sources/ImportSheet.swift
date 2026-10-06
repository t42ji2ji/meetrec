import AppKit
import SwiftUI

/// 匯入：拖檔案、選檔案，或貼 YouTube／Podcast／Spotify 網址
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
            HStack(spacing: 16) {
                ForEach(LinkSource.allCases, id: \.self) { s in
                    // 認出是哪個平台就只亮那個
                    SourceBadge(source: s).opacity(detected == nil || detected == s ? 1 : 0.3)
                }
            }
            .animation(.easeOut(duration: 0.15), value: detected)
            Text(L("Spotify 的音檔有版權保護，會改從 Apple Podcasts 下載同一集；Spotify 獨家節目沒辦法匯入。",
                   "Spotify audio is copy-protected, so the same episode is downloaded from Apple Podcasts instead. Spotify exclusives can’t be imported."))
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

enum LinkSource: CaseIterable {
    case youtube, applepodcasts, spotify

    init?(_ url: URL) {
        let host = url.host?.lowercased() ?? ""
        if host.hasSuffix("youtube.com") || host == "youtu.be" { self = .youtube }
        else if host == "podcasts.apple.com" { self = .applepodcasts }
        else if host.hasSuffix("spotify.com") { self = .spotify }
        else { return nil }
    }

    var name: String {
        switch self {
        case .youtube: "YouTube"
        case .applepodcasts: "Apple Podcasts"
        case .spotify: "Spotify"
        }
    }

    var color: Color {
        switch self {
        case .youtube: Color(red: 1, green: 0, blue: 0)
        case .applepodcasts: Color(red: 0.6, green: 0.2, blue: 0.8)
        case .spotify: Color(red: 0.12, green: 0.84, blue: 0.38)
        }
    }

    var mark: NSImage {
        NSImage(contentsOf: Bundle.main.resourceURL!.appendingPathComponent("icons/\(self).svg")) ?? NSImage()
    }
}

private struct SourceBadge: View {
    let source: LinkSource

    var body: some View {
        HStack(spacing: 6) {
            Image(nsImage: source.mark)
                .resizable()
                .renderingMode(.template)
                .foregroundStyle(source.color)
                .frame(width: 16, height: 16)
            Text(source.name).font(.callout)
        }
    }
}
