// 實驗：同一個 aggregate device 錄「瀏覽器程式聲音（process tap）」＋麥克風，各 buffer 存成 raw float32
import CoreAudio
import Foundation

let prefix = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "com.citrolabs.ego"
let seconds = CommandLine.arguments.count > 2 ? Double(CommandLine.arguments[2])! : 10
if CommandLine.arguments.count > 3 { FileManager.default.changeCurrentDirectoryPath(CommandLine.arguments[3]) }

func addr(_ sel: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: kAudioObjectPropertyElementMain)
}
func check(_ s: OSStatus, _ what: String) { if s != noErr { print("FAIL \(what): \(s)"); exit(1) } }
func getString(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector) -> String? {
    var a = addr(sel); var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size); var v: Unmanaged<CFString>? = nil
    guard AudioObjectGetPropertyData(obj, &a, 0, nil, &size, &v) == noErr, let s = v else { return nil }
    return s.takeRetainedValue() as String
}
func getU32(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector) -> UInt32 {
    var a = addr(sel); var size = UInt32(4); var v: UInt32 = 0
    AudioObjectGetPropertyData(obj, &a, 0, nil, &size, &v); return v
}
let sys = AudioObjectID(kAudioObjectSystemObject)

// 1. 找瀏覽器的 process objects
var a = addr(kAudioHardwarePropertyProcessObjectList); var size: UInt32 = 0
AudioObjectGetPropertyDataSize(sys, &a, 0, nil, &size)
var procs = [AudioObjectID](repeating: 0, count: Int(size) / 4)
AudioObjectGetPropertyData(sys, &a, 0, nil, &size, &procs)
let targets = procs.filter { (getString($0, kAudioProcessPropertyBundleID) ?? "").hasPrefix(prefix) }
for p in targets {
    print("tap target: \(getString(p, kAudioProcessPropertyBundleID)!) out=\(getU32(p, kAudioProcessPropertyIsRunningOutput)) in=\(getU32(p, kAudioProcessPropertyIsRunningInput))")
}
if targets.isEmpty && prefix != "GLOBAL" { print("FAIL no process matching \(prefix)"); exit(1) }

// 2. process tap
let desc = prefix == "GLOBAL" ? CATapDescription(stereoGlobalTapButExcludeProcesses: []) : CATapDescription(stereoMixdownOfProcesses: targets)
desc.uuid = UUID()
desc.isPrivate = true
var tapID = AudioObjectID(0)
check(AudioHardwareCreateProcessTap(desc, &tapID), "create tap")

// 3. 麥克風 UID
var mic = AudioObjectID(0); a = addr(kAudioHardwarePropertyDefaultInputDevice); size = 4
AudioObjectGetPropertyData(sys, &a, 0, nil, &size, &mic)
let micUID = getString(mic, kAudioDevicePropertyDeviceUID)!
var outDev = AudioObjectID(0); a = addr(kAudioHardwarePropertyDefaultOutputDevice); size = 4
AudioObjectGetPropertyData(sys, &a, 0, nil, &size, &outDev)
let outUID = getString(outDev, kAudioDevicePropertyDeviceUID)!
let mode = ProcessInfo.processInfo.environment["MODE"] ?? "mic"
print("mode", mode, "out", outUID)
print("mic: \(getString(mic, kAudioObjectPropertyName) ?? "?") uid=\(micUID)")

// 4. aggregate device：麥克風當時鐘，tap 掛上去
let agg: [String: Any] = [
    kAudioAggregateDeviceUIDKey: UUID().uuidString,
    kAudioAggregateDeviceNameKey: "recspike",
    kAudioAggregateDeviceIsPrivateKey: true,
    kAudioAggregateDeviceMainSubDeviceKey: mode == "out" ? outUID : micUID,
    kAudioAggregateDeviceSubDeviceListKey: mode == "out" ? [[kAudioSubDeviceUIDKey: outUID], [kAudioSubDeviceUIDKey: micUID, kAudioSubDeviceDriftCompensationKey: true]] : [[kAudioSubDeviceUIDKey: micUID]],
    kAudioAggregateDeviceTapListKey: [(ProcessInfo.processInfo.environment["NODRIFT"] != nil ? [kAudioSubTapUIDKey: desc.uuid.uuidString] : [kAudioSubTapUIDKey: desc.uuid.uuidString, kAudioSubTapDriftCompensationKey: true])],
    kAudioAggregateDeviceTapAutoStartKey: ProcessInfo.processInfo.environment["NOAUTO"] == nil,
]
var aggID = AudioObjectID(0)
check(AudioHardwareCreateAggregateDevice(agg as CFDictionary, &aggID), "create aggregate")

var rate = Float64(0); a = addr(kAudioDevicePropertyNominalSampleRate); size = 8
AudioObjectGetPropertyData(aggID, &a, 0, nil, &size, &rate)

// 5. IOProc：每個 input buffer 各存一份
let lock = NSLock()
var data: [Data] = []
var channels: [UInt32] = []
var procID: AudioDeviceIOProcID?
check(AudioDeviceCreateIOProcIDWithBlock(&procID, aggID, nil) { _, input, _, _, _ in
    let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
    lock.lock()
    if data.isEmpty { data = Array(repeating: Data(), count: list.count); channels = list.map { $0.mNumberChannels } }
    for (i, b) in list.enumerated() where i < data.count {
        if let p = b.mData { data[i].append(p.assumingMemoryBound(to: UInt8.self), count: Int(b.mDataByteSize)) }
    }
    lock.unlock()
}, "create ioproc")
check(AudioDeviceStart(aggID, procID), "start")
print("recording \(seconds)s at \(rate) Hz…"); fflush(stdout)
Thread.sleep(forTimeInterval: seconds)
AudioDeviceStop(aggID, procID)
AudioDeviceDestroyIOProcID(aggID, procID!)
AudioHardwareDestroyAggregateDevice(aggID)
AudioHardwareDestroyProcessTap(tapID)

lock.lock()
for (i, d) in data.enumerated() {
    let f = "buf\(i)_\(channels[i])ch_\(Int(rate)).f32"
    try! d.write(to: URL(fileURLWithPath: f))
    print("wrote \(f) \(d.count) bytes")
}
