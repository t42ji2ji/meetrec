import AppKit
import SwiftUI
import WebKit

/// AI 畫的圖（diagram-design 產生的 HTML），存在錄音資料夾裡。
/// 圖會跟著寬度重排，窄的地方會擠成一團，所以先用桌面寬度排版，再整個縮小到放得下
struct DiagramWebView: NSViewRepresentable {
    let url: URL
    /// 縮圖要連高度一起塞進去；大視窗可以捲，只要寬度放得下
    var fitHeight = false

    func makeNSView(context: Context) -> WKWebView {
        let web = WKWebView()
        web.navigationDelegate = context.coordinator
        web.setValue(false, forKey: "drawsBackground")
        web.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        return web
    }

    func updateNSView(_ web: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(fitHeight: fitHeight) }

    final class Coordinator: NSObject, WKNavigationDelegate {
        let fitHeight: Bool
        init(fitHeight: Bool) { self.fitHeight = fitHeight }

        func webView(_ web: WKWebView, didFinish navigation: WKNavigation!) {
            web.pageZoom = min(1, web.bounds.width / 1200)
            web.evaluateJavaScript("[document.documentElement.scrollWidth, document.documentElement.scrollHeight]") { [fitHeight] value, _ in
                guard let size = value as? [Double], size.count == 2, size[0] > 0, size[1] > 0 else { return }
                var zoom = web.bounds.width / size[0]
                if fitHeight { zoom = min(zoom, web.bounds.height / size[1]) }
                web.pageZoom = min(1, zoom)
            }
        }
    }
}

/// 側欄裡的縮圖，點一下開大視窗
struct DiagramCard: View {
    let url: URL

    var body: some View {
        DiagramWebView(url: url, fitHeight: true)
            .allowsHitTesting(false)
            .frame(height: 200)
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
