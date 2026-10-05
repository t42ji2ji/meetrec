import AVFoundation
import CoreAudio
import Foundation

enum RecorderError: Error, CustomStringConvertible {
    case noBrowserProcess, coreAudio(String, OSStatus)
    var description: String {
        switch self {
        case .noBrowserProcess: return "找不到瀏覽器的音訊程式"
        case .coreAudio(let what, let s): return "\(what) 失敗（\(s)）"
        }
    }
}

/// 一個 private aggregate device：麥克風當時鐘＋瀏覽器的 process tap。
/// 同一個 IOProc 拿到兩邊，寫成立體聲 AAC：左＝麥克風、右＝瀏覽器。
/// 錄音中寫 ADTS（.aac），每個封包都能單獨解碼，閃退或斷電也只少最後半秒；停止時才無損轉成 m4a（finalize）。
/// 預設麥克風換掉、瀏覽器的音訊程式換掉、或超過 3 秒收不到聲音（睡眠、裝置出錯）時重建裝置，繼續寫同一個檔；
/// 取樣率不同就轉成檔案的 48 kHz。
final class Recorder {
    /// 錄音中的 .aac
    let url: URL
    /// 出狀況時給使用者看的訊息，恢復後傳 nil（主執行緒）
    var onProblem: ((String?) -> Void)?
    private let browser: Browser
    private var tapID = AudioObjectID(0)
    private var aggID = AudioObjectID(0)
    private var procID: AudioDeviceIOProcID?
    private var file: AVAudioFile!
    private let fileFormat = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
    private var sessionFormat: AVAudioFormat!
    private var converter: AVAudioConverter?
    private let lock = NSLock()
    private var micBuf: [Float] = []
    private var tabBuf: [Float] = []
    private let writeQueue = DispatchQueue(label: "recorder.write")
    private var flushTimer: DispatchSourceTimer?
    private var micListener: AudioObjectPropertyListenerBlock?
    private var procListener: AudioObjectPropertyListenerBlock?
    private var tapped: Set<AudioObjectID> = []
    private var hasTap = false
    private var paused = false
    private var stopped = false
    private var lastInput = DispatchTime.now().uptimeNanoseconds
    private var problem: String?

    /// 暫停時丟掉收到的聲音，檔案裡直接接續
    func setPaused(_ p: Bool) {
        lock.lock()
        paused = p
        lock.unlock()
    }

    init(browser: Browser, url: URL) throws {
        self.browser = browser
        self.url = url.deletingPathExtension().appendingPathExtension("aac")
        file = try AVAudioFile(forWriting: self.url, settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: fileFormat.sampleRate,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 128_000,
        ], commonFormat: .pcmFormatFloat32, interleaved: false)
    }

    func start() throws {
        try startSession(requireBrowser: true)
        let t = DispatchSource.makeTimerSource(queue: writeQueue)
        t.schedule(deadline: .now() + 0.5, repeating: 0.5)
        t.setEventHandler { [weak self] in self?.flush() }
        t.resume()
        flushTimer = t

        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.restart() }
        var a = propAddress(kAudioHardwarePropertyDefaultInputDevice)
        AudioObjectAddPropertyListenerBlock(systemObject, &a, .main, listener)
        micListener = listener

        // 瀏覽器換了負責出聲的程式（或整個重開）時，tap 要跟著換
        let procs: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self, Set(self.browserProcesses()) != self.tapped else { return }
            self.restart()
        }
        a = propAddress(kAudioHardwarePropertyProcessObjectList)
        AudioObjectAddPropertyListenerBlock(systemObject, &a, .main, procs)
        procListener = procs
    }

    func stop() {
        stopped = true
        if let micListener {
            var a = propAddress(kAudioHardwarePropertyDefaultInputDevice)
            AudioObjectRemovePropertyListenerBlock(systemObject, &a, .main, micListener)
        }
        if let procListener {
            var a = propAddress(kAudioHardwarePropertyProcessObjectList)
            AudioObjectRemovePropertyListenerBlock(systemObject, &a, .main, procListener)
        }
        stopSession()
        flushTimer?.cancel()
        writeQueue.sync {
            flush()
            file = nil // 關檔
        }
    }

    /// 同一分鐘內又開新錄音時加編號，不能蓋掉前一個檔
    static func newURL(in folder: URL, name: String) -> URL {
        var candidate = name
        var n = 2
        while ["m4a", "aac"].contains(where: { FileManager.default.fileExists(atPath: folder.appendingPathComponent("\(candidate).\($0)").path) }) {
            candidate = "\(name) \(n)"
            n += 1
        }
        return folder.appendingPathComponent("\(candidate).m4a")
    }

    /// .aac 無損轉成同名 .m4a，成功才刪 .aac；失敗就留著 .aac（照樣能播）。回傳最後的檔案。
    static func finalize(_ aac: URL) -> URL {
        let m4a = aac.deletingPathExtension().appendingPathExtension("m4a")
        do {
            try run(Transcriber.ffmpeg, ["-v", "error", "-y", "-i", aac.path, "-c", "copy", "-metadata", "comment=\(Transcriber.tag)", m4a.path])
            try FileManager.default.removeItem(at: aac)
            return m4a
        } catch {
            try? FileManager.default.removeItem(at: m4a)
            return aac
        }
    }

    /// 主執行緒
    private func restart() {
        guard !stopped else { return }
        lock.lock()
        lastInput = DispatchTime.now().uptimeNanoseconds // 3 秒後還是沒聲音才再試
        lock.unlock()
        stopSession()
        writeQueue.sync { flush() } // 舊裝置的資料用舊取樣率寫完再換
        do {
            try startSession(requireBrowser: false)
        } catch {
            report("錄音裝置出錯，正在重試（\(error)）")
        }
    }

    private func browserProcesses() -> [AudioObjectID] {
        processObjects().filter { (getString($0, kAudioProcessPropertyBundleID) ?? "").hasPrefix(browser.bundlePrefix) }
    }

    /// 任何執行緒都可以呼叫；同樣的訊息只報一次
    private func report(_ message: String?) {
        DispatchQueue.main.async {
            guard message != self.problem else { return }
            self.problem = message
            self.onProblem?(message)
        }
    }

    /// 錄音中途瀏覽器的音訊程式全不見了（例如瀏覽器閃退）就只錄麥克風，不中斷
    private func startSession(requireBrowser: Bool) throws {
        let targets = browserProcesses()
        if targets.isEmpty && requireBrowser { throw RecorderError.noBrowserProcess }
        tapped = Set(targets)
        hasTap = !targets.isEmpty

        let desc = CATapDescription(stereoMixdownOfProcesses: targets)
        desc.uuid = UUID()
        desc.isPrivate = true
        if hasTap { try check(AudioHardwareCreateProcessTap(desc, &tapID), "建立瀏覽器音訊擷取") }

        var mic = AudioObjectID(0)
        var a = propAddress(kAudioHardwarePropertyDefaultInputDevice)
        var size = UInt32(4)
        AudioObjectGetPropertyData(systemObject, &a, 0, nil, &size, &mic)
        guard let micUID = getString(mic, kAudioDevicePropertyDeviceUID) else { throw RecorderError.coreAudio("讀取麥克風", -1) }

        let agg: [String: Any] = [
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceNameKey: "MeetRec",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceMainSubDeviceKey: micUID,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: micUID]],
            kAudioAggregateDeviceTapListKey: hasTap ? [[kAudioSubTapUIDKey: desc.uuid.uuidString, kAudioSubTapDriftCompensationKey: true]] : [],
            // 不能設 TapAutoStart：開著的話瀏覽器沒出聲時整個裝置（連麥克風）都不會跑
            kAudioAggregateDeviceTapAutoStartKey: false,
        ]
        try check(AudioHardwareCreateAggregateDevice(agg as CFDictionary, &aggID), "建立錄音裝置")

        var rate = Float64(48000)
        a = propAddress(kAudioDevicePropertyNominalSampleRate)
        size = 8
        AudioObjectGetPropertyData(aggID, &a, 0, nil, &size, &rate)
        writeQueue.sync {
            sessionFormat = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)
            converter = rate == fileFormat.sampleRate ? nil : AVAudioConverter(from: sessionFormat, to: fileFormat)
        }

        try check(AudioDeviceCreateIOProcIDWithBlock(&procID, aggID, nil) { [weak self] _, input, _, _, _ in
            self?.capture(input)
        }, "建立錄音回呼")
        try check(AudioDeviceStart(aggID, procID), "開始錄音")
    }

    private func stopSession() {
        AudioDeviceStop(aggID, procID)
        if let procID { AudioDeviceDestroyIOProcID(aggID, procID) }
        procID = nil
        AudioHardwareDestroyAggregateDevice(aggID)
        AudioHardwareDestroyProcessTap(tapID)
        aggID = 0
        tapID = 0
    }

    // 即時音訊執行緒：第一個 buffer 是麥克風、最後一個是瀏覽器 tap（沒有 tap 時右聲道補靜音），各取成單聲道
    private func capture(_ input: UnsafePointer<AudioBufferList>) {
        let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let tabIndex = list.count - 1
        guard list.count >= 1, let micData = list[0].mData else { return }
        let tabData = hasTap && tabIndex > 0 ? list[tabIndex].mData : nil
        let micCh = Int(max(1, list[0].mNumberChannels))
        let tabCh = Int(max(1, list[tabIndex].mNumberChannels))
        let micFrames = Int(list[0].mDataByteSize) / 4 / micCh
        let n = tabData == nil ? micFrames : min(micFrames, Int(list[tabIndex].mDataByteSize) / 4 / tabCh)
        let m = micData.assumingMemoryBound(to: Float.self)
        let t = tabData?.assumingMemoryBound(to: Float.self)
        lock.lock()
        defer { lock.unlock() }
        lastInput = DispatchTime.now().uptimeNanoseconds
        if paused { return }
        for i in 0..<n {
            micBuf.append(m[i * micCh])
            guard let t else { tabBuf.append(0); continue }
            var s: Float = 0
            for c in 0..<tabCh { s += t[i * tabCh + c] }
            tabBuf.append(s / Float(tabCh))
        }
    }

    private func flush() {
        lock.lock()
        let mic = micBuf, tab = tabBuf
        micBuf.removeAll(keepingCapacity: true)
        tabBuf.removeAll(keepingCapacity: true)
        let silentFor = DispatchTime.now().uptimeNanoseconds - lastInput
        lock.unlock()
        if !stopped, silentFor > 3_000_000_000 {
            report("收不到聲音，正在重新連接錄音裝置")
            DispatchQueue.main.async { self.restart() }
        }
        guard file != nil, !mic.isEmpty, let buf = AVAudioPCMBuffer(pcmFormat: sessionFormat, frameCapacity: AVAudioFrameCount(mic.count)) else { return }
        buf.frameLength = AVAudioFrameCount(mic.count)
        mic.withUnsafeBufferPointer { buf.floatChannelData![0].update(from: $0.baseAddress!, count: mic.count) }
        tab.withUnsafeBufferPointer { buf.floatChannelData![1].update(from: $0.baseAddress!, count: tab.count) }
        guard let converter else { write(buf); return }

        let capacity = AVAudioFrameCount(Double(mic.count) * fileFormat.sampleRate / sessionFormat.sampleRate) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: fileFormat, frameCapacity: capacity) else { return }
        var fed = false
        converter.convert(to: out, error: nil) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return buf
        }
        write(out)
    }

    private func write(_ buf: AVAudioPCMBuffer) {
        do {
            try file.write(from: buf)
            report(nil)
        } catch {
            report("錄音寫不進檔案：\(error.localizedDescription)")
        }
    }
}

private func check(_ s: OSStatus, _ what: String) throws {
    if s != noErr { throw RecorderError.coreAudio(what, s) }
}
