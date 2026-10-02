// 實驗：每秒列出正在使用麥克風的程式（Core Audio process objects）
import CoreAudio
import Foundation

func prop<T>(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector, _ initial: T) -> T? {
    var addr = AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var v = initial
    var size = UInt32(MemoryLayout<T>.size)
    return AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, &v) == noErr ? v : nil
}

func processes() -> [AudioObjectID] {
    var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size)
    var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids)
    return ids
}

var last = ""
while true {
    var rows: [String] = []
    for p in processes() {
        guard prop(p, kAudioProcessPropertyIsRunningInput, UInt32(0)) == 1 else { continue }
        let bundle = prop(p, kAudioProcessPropertyBundleID, "" as CFString).map { $0 as String } ?? "?"
        let pid = prop(p, kAudioProcessPropertyPID, pid_t(0)) ?? 0
        rows.append("\(bundle) pid=\(pid)")
    }
    let now = rows.sorted().joined(separator: ", ")
    if now != last {
        print("\(Date()) mic in use by: \(now.isEmpty ? "(none)" : now)")
        fflush(stdout)
        last = now
    }
    Thread.sleep(forTimeInterval: 1)
}
