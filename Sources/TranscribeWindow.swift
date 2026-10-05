import AppKit
import UniformTypeIdentifiers

/// 把音檔拖進來（或選檔）轉逐字稿；排隊一個一個轉，每個檔案一列顯示狀態
final class TranscribeWindow: NSWindow {
    private let list = NSStackView()
    private let recordings: URL

    init(recordings: URL) {
        self.recordings = recordings
        super.init(contentRect: NSRect(x: 0, y: 0, width: 480, height: 380), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        title = "轉逐字稿"
        isReleasedWhenClosed = false
        minSize = NSSize(width: 380, height: 280)

        let drop = DropZone(onDrop: { [weak self] in self?.add($0) }, onChoose: { [weak self] in self?.choose() })

        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 8
        list.translatesAutoresizingMaskIntoConstraints = false
        let doc = FlippedView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(list)
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.documentView = doc

        let stack = NSStackView(views: [drop, scroll])
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        contentView = stack
        NSLayoutConstraint.activate([
            drop.heightAnchor.constraint(equalToConstant: 120),
            doc.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            doc.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            doc.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            list.leadingAnchor.constraint(equalTo: doc.leadingAnchor),
            list.trailingAnchor.constraint(equalTo: doc.trailingAnchor),
            list.topAnchor.constraint(equalTo: doc.topAnchor),
            list.bottomAnchor.constraint(equalTo: doc.bottomAnchor),
        ])
        center()
    }

    private func choose() {
        let p = NSOpenPanel()
        p.allowsMultipleSelection = true
        p.allowedContentTypes = [.audio, .movie]
        p.directoryURL = recordings
        p.beginSheetModal(for: self) { [weak self] r in if r == .OK { self?.add(p.urls) } }
    }

    private func add(_ urls: [URL]) {
        for url in urls {
            let row = FileRow(url)
            list.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
            // 會議錄音資料夾裡的是 MeetRec 錄的，左右聲道分得出我和對方
            let speakers = url.standardizedFileURL.path.hasPrefix(recordings.standardizedFileURL.path + "/")
            Transcriber.queue.async {
                DispatchQueue.main.async { row.status = "轉換中…" }
                let result = Result { try Transcriber.transcribe(url, speakers: speakers) }
                DispatchQueue.main.async { row.finish(result) }
            }
        }
    }
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// 虛線框的拖放區，中間有「選擇檔案…」按鈕
private final class DropZone: NSView {
    private let onDrop: ([URL]) -> Void
    private let onChoose: () -> Void
    private let border = CAShapeLayer()
    private var highlighted = false { didSet { updateColors() } }

    init(onDrop: @escaping ([URL]) -> Void, onChoose: @escaping () -> Void) {
        self.onDrop = onDrop
        self.onChoose = onChoose
        super.init(frame: .zero)
        wantsLayer = true
        border.fillColor = nil
        border.lineWidth = 1.5
        border.lineDashPattern = [6, 4]
        layer?.addSublayer(border)
        registerForDraggedTypes([.fileURL])

        let label = NSTextField(labelWithString: "把音檔拖到這裡")
        label.font = .systemFont(ofSize: 14, weight: .medium)
        label.textColor = .secondaryLabelColor
        let button = NSButton(title: "選擇檔案…", target: self, action: #selector(choose))
        let stack = NSStackView(views: [label, button])
        stack.orientation = .vertical
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        updateColors()
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc private func choose() { onChoose() }

    override func layout() {
        super.layout()
        border.frame = bounds
        border.path = CGPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), cornerWidth: 10, cornerHeight: 10, transform: nil)
    }

    override func viewDidChangeEffectiveAppearance() { updateColors() }

    private func updateColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            border.strokeColor = (highlighted ? NSColor.controlAccentColor : .tertiaryLabelColor).cgColor
            layer?.backgroundColor = highlighted ? NSColor.controlAccentColor.withAlphaComponent(0.08).cgColor : nil
        }
    }

    private func urls(_ info: NSDraggingInfo) -> [URL] {
        info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }

    override func draggingEntered(_ info: NSDraggingInfo) -> NSDragOperation {
        guard !urls(info).isEmpty else { return [] }
        highlighted = true
        return .copy
    }
    override func draggingExited(_ info: NSDraggingInfo?) { highlighted = false }
    override func performDragOperation(_ info: NSDraggingInfo) -> Bool {
        highlighted = false
        onDrop(urls(info))
        return true
    }
}

/// 一個檔案：檔名、狀態，轉完出現「打開」和「在 Finder 顯示」
private final class FileRow: NSStackView {
    private let url: URL
    private let statusLabel = NSTextField(labelWithString: "等待中")
    var status: String {
        get { statusLabel.stringValue }
        set { statusLabel.stringValue = newValue }
    }

    init(_ url: URL) {
        self.url = url
        super.init(frame: .zero)
        let name = NSTextField(labelWithString: url.lastPathComponent)
        name.lineBreakMode = .byTruncatingMiddle
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setContentCompressionResistancePriority(.defaultLow + 1, for: .horizontal)
        orientation = .horizontal
        spacing = 8
        setViews([name, statusLabel], in: .leading)
    }
    required init?(coder: NSCoder) { fatalError() }

    func finish(_ result: Result<URL, Error>) {
        switch result {
        case .success(let txt):
            status = "完成"
            let srt = txt.deletingPathExtension().appendingPathExtension("srt")
            addView(RowButton("打開 txt") { NSWorkspace.shared.open(txt) }, in: .trailing)
            addView(RowButton("在 Finder 顯示") { NSWorkspace.shared.activateFileViewerSelecting([txt, srt]) }, in: .trailing)
        case .failure(let error):
            status = "失敗：\(error)"
            statusLabel.textColor = .systemRed
        }
    }
}

private final class RowButton: NSButton {
    private var handler: () -> Void = {}
    convenience init(_ title: String, _ action: @escaping () -> Void) {
        self.init(title: title, target: nil, action: #selector(fire))
        target = self
        handler = action
        controlSize = .small
        bezelStyle = .inline
    }
    @objc private func fire() { handler() }
}
