import AppKit
import SwiftUI
import WebKit

/// AI 畫的圖（diagram-design 產生的 HTML），存在錄音資料夾裡。
/// 圖會跟著寬度重排，窄的地方會擠成一團，所以先用桌面寬度排版，再整個縮小到放得下
struct DiagramWebView: NSViewRepresentable {
    let url: URL
    /// 縮圖用：只留最大的那張 SVG 撐滿，回報它的寬高比讓卡片跟著調高度。nil 就是大視窗，整頁照排、寬度放得下
    var thumbnail: ((Double) -> Void)? = nil

    func makeNSView(context: Context) -> WKWebView {
        let web = WKWebView()
        web.navigationDelegate = context.coordinator
        web.setValue(false, forKey: "drawsBackground")
        web.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        return web
    }

    func updateNSView(_ web: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(thumbnail: thumbnail) }

    final class Coordinator: NSObject, WKNavigationDelegate {
        let thumbnail: ((Double) -> Void)?
        init(thumbnail: ((Double) -> Void)?) { self.thumbnail = thumbnail }

        /// 把面積最大、有 viewBox 的 SVG 拿出來單獨撐滿頁面（標題、圖例、留白都不要），回傳寬高比；找不到回 0。
        /// 有好幾張大圖的是報告，整頁保留、回 -1
        private static let isolate = """
        (() => {
          const area = e => { const r = e.getBoundingClientRect(); return r.width * r.height };
          const svgs = [...document.querySelectorAll('svg')].filter(e => e.viewBox.baseVal && e.viewBox.baseVal.width > 0)
            .sort((a, b) => area(b) - area(a));
          if (svgs.length > 1 && area(svgs[1]) > 40000) return -1;
          const svg = svgs[0];
          if (!svg) return 0;
          const box = svg.viewBox.baseVal;
          document.body.replaceChildren(svg);
          document.body.style.cssText = 'margin:0;padding:12px;box-sizing:border-box;height:100vh';
          svg.removeAttribute('width'); svg.removeAttribute('height');
          svg.style.cssText = 'display:block;width:100%;height:100%;min-width:0;max-width:none;min-height:0;max-height:none';
          return box.width / box.height;
        })()
        """

        func webView(_ web: WKWebView, didFinish navigation: WKNavigation!) {
            web.pageZoom = min(1, web.bounds.width / 1200)
            guard let thumbnail else { return }
            web.evaluateJavaScript(Self.isolate) { value, _ in
                if let aspect = value as? Double, aspect > 0 {
                    web.pageZoom = 1
                    thumbnail(aspect)
                } else if let aspect = value as? Double, aspect < 0 {
                    // 報告：照桌面寬度排的整頁，卡片露出開頭那段
                    thumbnail(0.9)
                } else {
                    // 沒有 SVG 的話整頁縮到放得下
                    web.evaluateJavaScript("[document.documentElement.scrollWidth, document.documentElement.scrollHeight]") { value, _ in
                        guard let size = value as? [Double], size.count == 2, size[0] > 0, size[1] > 0 else { return }
                        web.pageZoom = min(1, web.bounds.width / size[0], web.bounds.height / size[1])
                    }
                }
            }
        }
    }
}

/// 側欄裡的縮圖，點一下開大視窗
struct DiagramCard: View {
    let url: URL
    /// 圖的寬高比，載入後才知道；卡片高度跟著它，太扁太高都有個限度
    @State private var aspect = 1.6
    @State private var width: CGFloat = 0

    var body: some View {
        DiagramWebView(url: url, thumbnail: { aspect = $0 })
            .allowsHitTesting(false)
            .frame(height: width > 0 ? min(420, max(140, (width - 24) / aspect + 24)) : 200)
            .frame(maxWidth: .infinity)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            .background(.background)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.separator))
            .overlay(alignment: .bottomTrailing) {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 11, weight: .semibold))
                    .padding(6)
                    .background(.regularMaterial, in: Circle())
                    .padding(8)
            }
            .contentShape(Rectangle())
            .onTapGesture { DiagramWindow.show(url) }
            .help(L("放大", "Enlarge"))
    }
}

@MainActor
enum DiagramWindow {
    /// 開著的視窗；同一張圖再點就叫到前面
    private static var windows: [URL: NSWindow] = [:]

    static func show(_ url: URL) {
        if let w = windows[url] { return w.makeKeyAndOrderFront(nil) }
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 760),
                         styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        w.title = url.deletingPathExtension().lastPathComponent
        w.isReleasedWhenClosed = false
        w.contentView = NSHostingView(rootView: DiagramWebView(url: url).background(.background))
        w.center()
        w.makeKeyAndOrderFront(nil)
        windows[url] = w
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { _ in
            MainActor.assumeIsolated { windows[url] = nil }
        }
    }
}
