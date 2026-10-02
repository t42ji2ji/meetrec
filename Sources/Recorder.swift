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
/// 同一個 IOProc 拿到兩邊，寫成立體聲 m4a：左＝麥克風、右＝瀏覽器。
final class Recorder {
    let url: URL
    private var tapID = AudioObjectID(0)
    private var aggID = AudioObjectID(0)
    private var procID: AudioDeviceIOProcID?
    private var file: AVAudioFile!
    private var format: AVAudioFormat!
    private let lock = NSLock()
    private var micBuf: [Float] = []
    private var tabBuf: [Float] = []
    private let writeQueue = DispatchQueue(label: "recorder.write")
    private var flushTimer: DispatchSourceTimer?

    init(browser: Browser, url: URL) throws {
        self.url = url
        let targets = processObjects().filter { (getString($0, kAudioProcessPropertyBundleID) ?? "").hasPrefix(browser.bundlePrefix) }
        guard !targets.isEmpty else { throw RecorderError.noBrowserProcess }

        let desc = CATapDescription(stereoMixdownOfProcesses: targets)
        desc.uuid = UUID()
        desc.isPrivate = true
        try check(AudioHardwareCreateProcessTap(desc, &tapID), "建立瀏覽器音訊擷取")

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
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: desc.uuid.uuidString, kAudioSubTapDriftCompensationKey: true]],
            // 不能設 TapAutoStart：開著的話瀏覽器沒出聲時整個裝置（連麥克風）都不會跑
            kAudioAggregateDeviceTapAutoStartKey: false,
        ]
        try check(AudioHardwareCreateAggregateDevice(agg as CFDictionary, &aggID), "建立錄音裝置")

        var rate = Float64(48000)
        a = propAddress(kAudioDevicePropertyNominalSampleRate)
        size = 8
        AudioObjectGetPropertyData(aggID, &a, 0, nil, &size, &rate)
        format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)
        file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: rate,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 128_000,
        ], commonFormat: .pcmFormatFloat32, interleaved: false)
    }

    func start() throws {
        try check(AudioDeviceCreateIOProcIDWithBlock(&procID, aggID, nil) { [weak self] _, input, _, _, _ in
            self?.capture(input)
        }, "建立錄音回呼")
        try check(AudioDeviceStart(aggID, procID), "開始錄音")
        let t = DispatchSource.makeTimerSource(queue: writeQueue)
        t.schedule(deadline: .now() + 0.5, repeating: 0.5)
        t.setEventHandler { [weak self] in self?.flush() }
        t.resume()
        flushTimer = t
    }

    func stop() {
        AudioDeviceStop(aggID, procID)
        if let procID { AudioDeviceDestroyIOProcID(aggID, procID) }
        AudioHardwareDestroyAggregateDevice(aggID)
        AudioHardwareDestroyProcessTap(tapID)
        flushTimer?.cancel()
        writeQueue.sync {
            flush()
            file = nil // 關檔
        }
    }

    // 即時音訊執行緒：第一個 buffer 是麥克風、最後一個是瀏覽器 tap，各取成單聲道
    private func capture(_ input: UnsafePointer<AudioBufferList>) {
        let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        guard list.count >= 2, let micData = list[0].mData, let tabData = list[list.count - 1].mData else { return }
        let micCh = Int(max(1, list[0].mNumberChannels))
        let tabCh = Int(max(1, list[list.count - 1].mNumberChannels))
        let micFrames = Int(list[0].mDataByteSize) / 4 / micCh
        let tabFrames = Int(list[list.count - 1].mDataByteSize) / 4 / tabCh
        let n = min(micFrames, tabFrames)
        let m = micData.assumingMemoryBound(to: Float.self)
        let t = tabData.assumingMemoryBound(to: Float.self)
        lock.lock()
        for i in 0..<n {
            micBuf.append(m[i * micCh])
            var s: Float = 0
            for c in 0..<tabCh { s += t[i * tabCh + c] }
            tabBuf.append(s / Float(tabCh))
        }
        lock.unlock()
    }

    private func flush() {
        lock.lock()
        let mic = micBuf, tab = tabBuf
        micBuf.removeAll(keepingCapacity: true)
        tabBuf.removeAll(keepingCapacity: true)
        lock.unlock()
        guard file != nil, !mic.isEmpty, let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(mic.count)) else { return }
        buf.frameLength = AVAudioFrameCount(mic.count)
        mic.withUnsafeBufferPointer { buf.floatChannelData![0].update(from: $0.baseAddress!, count: mic.count) }
        tab.withUnsafeBufferPointer { buf.floatChannelData![1].update(from: $0.baseAddress!, count: tab.count) }
        try? file.write(from: buf)
    }
}

private func check(_ s: OSStatus, _ what: String) throws {
    if s != noErr { throw RecorderError.coreAudio(what, s) }
}
