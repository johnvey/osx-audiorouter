import CoreAudio
import Foundation

let systemObjectID = AudioObjectID(kAudioObjectSystemObject)

func propertyAddress(
    _ selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
    element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
}

func getObjectIDArray(_ objectID: AudioObjectID, _ selector: AudioObjectPropertySelector) -> [AudioObjectID] {
    var addr = propertyAddress(selector)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(objectID, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
    var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    guard AudioObjectGetPropertyData(objectID, &addr, 0, nil, &size, &ids) == noErr else { return [] }
    return ids
}

func getString(_ objectID: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
    var addr = propertyAddress(selector)
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    var value: Unmanaged<CFString>? = nil
    let status = withUnsafeMutablePointer(to: &value) { ptr in
        AudioObjectGetPropertyData(objectID, &addr, 0, nil, &size, ptr)
    }
    guard status == noErr else { return nil }
    return value?.takeRetainedValue() as String?
}

func getUInt32(_ objectID: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
    var addr = propertyAddress(selector)
    var size = UInt32(MemoryLayout<UInt32>.size)
    var value: UInt32 = 0
    guard AudioObjectGetPropertyData(objectID, &addr, 0, nil, &size, &value) == noErr else { return nil }
    return value
}

func getPID(_ objectID: AudioObjectID, _ selector: AudioObjectPropertySelector) -> pid_t? {
    var addr = propertyAddress(selector)
    var size = UInt32(MemoryLayout<pid_t>.size)
    var value: pid_t = 0
    guard AudioObjectGetPropertyData(objectID, &addr, 0, nil, &size, &value) == noErr else { return nil }
    return value
}

/// Number of output channels a device exposes; 0 means it is not an output device.
func outputChannelCount(_ deviceID: AudioObjectID) -> Int {
    var addr = propertyAddress(kAudioDevicePropertyStreamConfiguration, scope: kAudioObjectPropertyScopeOutput)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(deviceID, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
    let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
    defer { raw.deallocate() }
    guard AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, raw) == noErr else { return 0 }
    let abl = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
    return abl.reduce(0) { $0 + Int($1.mNumberChannels) }
}
