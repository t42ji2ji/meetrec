import CoreAudio

let systemObject = AudioObjectID(kAudioObjectSystemObject)

func propAddress(_ sel: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: kAudioObjectPropertyElementMain)
}

func getString(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector) -> String? {
    var a = propAddress(sel)
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    var v: Unmanaged<CFString>? = nil
    guard AudioObjectGetPropertyData(obj, &a, 0, nil, &size, &v) == noErr, let s = v else { return nil }
    return s.takeRetainedValue() as String
}

func getUInt32(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector) -> UInt32 {
    var a = propAddress(sel)
    var size = UInt32(4)
    var v: UInt32 = 0
    AudioObjectGetPropertyData(obj, &a, 0, nil, &size, &v)
    return v
}

func processObjects() -> [AudioObjectID] {
    var a = propAddress(kAudioHardwarePropertyProcessObjectList)
    var size: UInt32 = 0
    AudioObjectGetPropertyDataSize(systemObject, &a, 0, nil, &size)
    var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    AudioObjectGetPropertyData(systemObject, &a, 0, nil, &size, &ids)
    return ids
}
