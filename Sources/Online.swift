import Foundation

/// 從網址抓聲音：YouTube、Apple Podcasts 和其他 yt-dlp 支援的網站。
/// Spotify 有 DRM 抓不了，改找 Apple Podcasts 上同一集（Spotify 獨家的節目就沒辦法）。
/// yt-dlp 不放進 app：YouTube 常改版，第一次用時下載到 Application Support，抓失敗就讓它自己更新再試一次
enum Online {
    static let ytdlp = Transcriber.dir + "/yt-dlp"

    /// 下載到 dir，回傳音檔位置。在背景執行緒呼叫；progress 0...1
    static func download(_ link: URL, into dir: URL, progress: @escaping (Double) -> Void) throws -> URL {
        try installYtdlp()
        let target = link.host?.hasSuffix("spotify.com") == true ? try applePodcastsURL(forSpotify: link) : link
        do {
            return try run(target, into: dir, progress: progress)
        } catch {
            _ = try? exec(["-U"])
            return try run(target, into: dir, progress: progress)
        }
    }

    private static func installYtdlp() throws {
        guard !FileManager.default.isExecutableFile(atPath: ytdlp) else { return }
        let url = URL(string: "https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp_macos")!
        let (tmp, response) = try Media.wait { try await URLSession.shared.download(from: url) }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw OnlineError.ytdlpDownload }
        try FileManager.default.createDirectory(atPath: Transcriber.dir, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(atPath: ytdlp)
        try FileManager.default.moveItem(atPath: tmp.path, toPath: ytdlp)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: ytdlp)
    }

    /// AVFoundation 讀不了 webm／opus，只挑 m4a、mp3，再不行拿 mp4 影片（匯入時會抽出聲音）
    private static func run(_ link: URL, into dir: URL, progress: @escaping (Double) -> Void) throws -> URL {
        var last = ""
        let (status, errors) = try exec(["--no-playlist", "-f", "bestaudio[ext=m4a]/bestaudio[ext=mp3]/best[ext=mp4]",
                            "--newline", "--progress", "--progress-template", "download:%(progress.downloaded_bytes)s/%(progress.total_bytes,progress.total_bytes_estimate)s",
                            "--print", "after_move:filepath", "-o", dir.path + "/%(title).150B.%(ext)s", link.absoluteString]) { line in
            let parts = line.split(separator: "/")
            if parts.count == 2, let done = Double(parts[0]), let total = Double(parts[1]), total > 0 {
                progress(min(done / total, 1))
            } else if !line.isEmpty {
                last = line
            }
        }
        guard status == 0, FileManager.default.fileExists(atPath: last) else { throw OnlineError.failed(errors) }
        return URL(fileURLWithPath: last)
    }

    /// 執行 yt-dlp，stdout 一行一行交給 line；回傳結束碼和 stderr 裡的 ERROR 訊息
    @discardableResult
    private static func exec(_ args: [String], line: @escaping (String) -> Void = { _ in }) throws -> (Int32, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: ytdlp)
        p.arguments = args
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        var buffer = Data()
        out.fileHandleForReading.readabilityHandler = { h in
            buffer.append(h.availableData)
            while let i = buffer.firstIndex(of: 10) {
                line(String(decoding: buffer[..<i], as: UTF8.self))
                buffer.removeSubrange(...i)
            }
        }
        try p.run()
        let stderr = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        out.fileHandleForReading.readabilityHandler = nil
        if !buffer.isEmpty { line(String(decoding: buffer, as: UTF8.self)) }
        let errors = String(decoding: stderr, as: UTF8.self).split(separator: "\n").filter { $0.hasPrefix("ERROR") }.joined(separator: "\n")
        return (p.terminationStatus, errors)
    }

    /// Spotify 集數頁的標題和節目名，拿去 iTunes 搜尋找同一集
    private static func applePodcastsURL(forSpotify link: URL) throws -> URL {
        var request = URLRequest(url: link)
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        let (data, _) = try Media.wait { [request] in try await URLSession.shared.data(for: request) }
        let html = String(decoding: data, as: UTF8.self)
        func meta(_ name: String) -> String? {
            guard let r = html.range(of: "property=\"\(name)\" content=\"") else { return nil }
            let rest = html[r.upperBound...]
            return rest.firstIndex(of: "\"").map { decodeEntities(String(rest[..<$0])) }
        }
        // og:description 是「節目名 · Episode」
        guard link.path.hasPrefix("/episode/"), let title = meta("og:title"),
              let show = meta("og:description")?.components(separatedBy: " · ").first else { throw OnlineError.spotifyNotEpisode }
        var query = URLComponents(string: "https://itunes.apple.com/search")!
        query.queryItems = [.init(name: "media", value: "podcast"), .init(name: "entity", value: "podcastEpisode"),
                            .init(name: "limit", value: "10"), .init(name: "term", value: "\(title) \(show)")]
        let search = query.url!
        let (json, _) = try Media.wait { try await URLSession.shared.data(from: search) }
        struct Results: Decodable {
            struct Episode: Decodable { let trackName: String; let collectionName: String; let trackViewUrl: URL }
            let results: [Episode]
        }
        let fold = { (s: String) in s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil).trimmingCharacters(in: .whitespaces) }
        let episodes = try JSONDecoder().decode(Results.self, from: json).results
        guard let match = episodes.first(where: { fold($0.trackName) == fold(title) && fold($0.collectionName) == fold(show) }) else {
            throw OnlineError.spotifyOnly(title)
        }
        return match.trackViewUrl
    }

    private static func decodeEntities(_ s: String) -> String {
        [("&amp;", "&"), ("&quot;", "\""), ("&#x27;", "'"), ("&#39;", "'"), ("&lt;", "<"), ("&gt;", ">")]
            .reduce(s) { $0.replacingOccurrences(of: $1.0, with: $1.1) }
    }
}

enum OnlineError: Error, CustomStringConvertible {
    case ytdlpDownload
    case failed(String)
    case spotifyNotEpisode
    case spotifyOnly(String)
    var description: String {
        switch self {
        case .ytdlpDownload: return L("下載工具（yt-dlp）下載失敗", "Couldn’t download the downloader (yt-dlp)")
        case .failed(let e): return L("抓不到這個網址的聲音", "Couldn’t get audio from this link") + (e.isEmpty ? "" : "\n\n" + e)
        case .spotifyNotEpisode: return L("Spotify 只支援單集網址（open.spotify.com/episode/…）", "Only Spotify episode links work (open.spotify.com/episode/…)")
        case .spotifyOnly(let t): return L("Spotify 有版權保護，抓不了。「\(t)」在 Apple Podcasts 找不到同一集，可能是 Spotify 獨家。", "Spotify audio is copy-protected. “\(t)” isn’t on Apple Podcasts, so it may be a Spotify exclusive.")
        }
    }
}
