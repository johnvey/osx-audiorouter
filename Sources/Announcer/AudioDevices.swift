import CoreAudio
import Foundation

struct AudioOutputDevice: Equatable {
    let id: AudioObjectID
    let uid: String
    let name: String
}

enum AudioDevices {
    /// All devices that can render audio, excluding aggregates Announcer creates for itself.
    static func outputDevices() -> [AudioOutputDevice] {
        getObjectIDArray(systemObjectID, kAudioHardwarePropertyDevices).compactMap { id in
            guard outputChannelCount(id) > 0 else { return nil }
            guard let uid = getString(id, kAudioDevicePropertyDeviceUID),
                  let name = getString(id, kAudioObjectPropertyName) else { return nil }
            guard !uid.hasPrefix(RouteEngine.aggregateUIDPrefix) else { return nil }
            return AudioOutputDevice(id: id, uid: uid, name: name)
        }
    }

    static func device(forUID uid: String) -> AudioOutputDevice? {
        outputDevices().first { $0.uid == uid }
    }

    static func defaultOutputDevice() -> AudioOutputDevice? {
        var addr = propertyAddress(kAudioHardwarePropertyDefaultOutputDevice)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var id = AudioObjectID(kAudioObjectUnknown)
        guard AudioObjectGetPropertyData(systemObjectID, &addr, 0, nil, &size, &id) == noErr,
              id != kAudioObjectUnknown,
              let uid = getString(id, kAudioDevicePropertyDeviceUID),
              let name = getString(id, kAudioObjectPropertyName) else { return nil }
        return AudioOutputDevice(id: id, uid: uid, name: name)
    }
}

struct AudioProcessEntry {
    let objectID: AudioObjectID
    let pid: pid_t
    let bundleID: String?
    let isRunningOutput: Bool
}

enum AudioProcesses {
    /// Every process CoreAudio knows about (i.e., processes that have registered as audio clients).
    static func all() -> [AudioProcessEntry] {
        getObjectIDArray(systemObjectID, kAudioHardwarePropertyProcessObjectList).compactMap { oid in
            guard let pid = getPID(oid, kAudioProcessPropertyPID) else { return nil }
            let bundleID = getString(oid, kAudioProcessPropertyBundleID)
            let running = (getUInt32(oid, kAudioProcessPropertyIsRunningOutput) ?? 0) != 0
            return AudioProcessEntry(objectID: oid, pid: pid, bundleID: bundleID, isRunningOutput: running)
        }
    }
}
