import AppKit
// 產生 Resources/AppIcon.icns（概念：黑底、紅色錄音點、三行逐字稿）。用法：swift tools/make-icon.swift
// macOS 圖示格線：1024 畫布、824 主體、圓角 185，主體下方留陰影
func draw(_ s: CGFloat) -> NSImage {
    NSImage(size: NSSize(width: s, height: s), flipped: true) { _ in
        let ctx = NSGraphicsContext.current!.cgContext
        ctx.scaleBy(x: s / 1024, y: s / 1024)
        let body = CGRect(x: 100, y: 100, width: 824, height: 824)
        let shape = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 10), blur: 24, color: NSColor.black.withAlphaComponent(0.28).cgColor)
        ctx.addPath(shape); ctx.setFillColor(CGColor(red: 0.09, green: 0.09, blue: 0.09, alpha: 1)); ctx.fillPath()
        ctx.restoreGState()
        // 位置用主體的比例：紅點在左上，三行字靠左對齊在下面
        func x(_ f: CGFloat) -> CGFloat { body.minX + body.width * f }
        func y(_ f: CGFloat) -> CGFloat { body.minY + body.height * f }
        let r = body.width * 0.115
        ctx.setFillColor(CGColor(red: 0.93, green: 0.16, blue: 0.17, alpha: 1))
        ctx.fillEllipse(in: CGRect(x: x(0.25) - r, y: y(0.28) - r, width: r * 2, height: r * 2))
        let h = body.height * 0.085
        ctx.setFillColor(CGColor(red: 0.96, green: 0.94, blue: 0.90, alpha: 1))
        for (i, w) in [CGFloat(0.44), 0.44, 0.44].enumerated() {
            let rect = CGRect(x: x(0.14), y: y(0.48) + CGFloat(i) * h * 1.55, width: body.width * w, height: h)
            ctx.addPath(CGPath(roundedRect: rect, cornerWidth: h / 2, cornerHeight: h / 2, transform: nil)); ctx.fillPath()
        }
        return true
    }
}
func png(_ img: NSImage, _ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    img.draw(in: NSRect(x: 0, y: 0, width: px, height: px))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}
let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
let set = root.appendingPathComponent("build/AppIcon.iconset")
try? FileManager.default.removeItem(at: set)
try! FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try! png(draw(CGFloat(base)), base).write(to: set.appendingPathComponent("icon_\(base)x\(base).png"))
    try! png(draw(CGFloat(base * 2)), base * 2).write(to: set.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
try! png(draw(1024), 1024).write(to: root.appendingPathComponent("build/AppIcon-1024.png"))
