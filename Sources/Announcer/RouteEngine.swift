import AudioToolbox
import CoreAudio
import Foundation
import os

/// Owns all active audio routes. For each rule (app bundle ID -> output device UID) whose app has
/// live audio process objects, it creates a process tap that mutes the app's normal output and an
/// IO proc on a private aggregate device that re-renders the tapped audio to the chosen device.
///
/// Main-thread confined except for the realtime IO blocks.
final class RouteEngine {
    static let aggregateUIDPrefix = "com.johnvey.announcer.aggregate."

    private struct Route {
        let bundleID: String
        let deviceUID: String
        let processObjectIDs: Set<AudioObjectID>
        let tapID: AudioObjectID
        let aggregateID: AudioObjectID
        let procID: AudioDeviceIOProcID
    }

    /// Audio for some apps is produced by a differently-named helper process.
    private static let bundleAliases: [String: Set<String>] = [
        "com.apple.Safari": ["com.apple.WebKit.GPU"]
    ]

    private let log = Logger(subsystem: "com.johnvey.announcer", category: "RouteEngine")
    private let store = RuleStore()
    private var routes: [String: Route] = [:]
    private var reconcilePending = false
    private var listenerBlock: AudioObjectPropertyListenerBlock?

    /// bundleID -> output device UID
    private(set) var rules: [String: String]

    /// Fired after routes change so the UI can refresh.
    var onChange: (() -> Void)?

    init() {
        rules = store.load()
    }

    func start() {
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            DispatchQueue.main.async { self?.scheduleReconcile() }
        }
        listenerBlock = block
        var processAddr = propertyAddress(kAudioHardwarePropertyProcessObjectList)
        var deviceAddr = propertyAddress(kAudioHardwarePropertyDevices)
        AudioObjectAddPropertyListenerBlock(systemObjectID, &processAddr, DispatchQueue.main, block)
        AudioObjectAddPropertyListenerBlock(systemObjectID, &deviceAddr, DispatchQueue.main, block)
        reconcile()
    }

    /// True if audio is currently being actively re-routed for this app.
    func isRouteActive(bundleID: String) -> Bool {
        routes[bundleID] != nil
    }

    func setRule(bundleID: String, deviceUID: String?) {
        if let deviceUID {
            rules[bundleID] = deviceUID
        } else {
            rules.removeValue(forKey: bundleID)
        }
        store.save(rules)
        reconcile()
    }

    func teardownAll() {
        for bundleID in Array(routes.keys) {
            teardownRoute(bundleID: bundleID)
        }
    }

    // MARK: - Reconciliation

    private func scheduleReconcile() {
        guard !reconcilePending else { return }
        reconcilePending = true
        // Coalesce bursts of device/process notifications.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self else { return }
            self.reconcilePending = false
            self.reconcile()
        }
    }

    private func reconcile() {
        let devices = AudioDevices.outputDevices()
        let processes = AudioProcesses.all()

        for (bundleID, deviceUID) in rules {
            let desired = Set(
                processes
                    .filter { Self.processMatches(rule: bundleID, processBundleID: $0.bundleID) }
                    .map(\.objectID)
            )
            let device = devices.first { $0.uid == deviceUID }

            if desired.isEmpty || device == nil {
                // App has no audio presence or device unplugged: no route needed right now.
                if routes[bundleID] != nil { teardownRoute(bundleID: bundleID) }
                continue
            }

            if let existing = routes[bundleID] {
                if existing.deviceUID == deviceUID && existing.processObjectIDs == desired { continue }
                teardownRoute(bundleID: bundleID)
            }

            do {
                try buildRoute(bundleID: bundleID, device: device!, processObjectIDs: desired)
            } catch {
                log.error("Failed to build route for \(bundleID, privacy: .public): \(error, privacy: .public)")
            }
        }

        // Rules removed while a route was live.
        for bundleID in Array(routes.keys) where rules[bundleID] == nil {
            teardownRoute(bundleID: bundleID)
        }

        onChange?()
    }

    private static func processMatches(rule bundleID: String, processBundleID: String?) -> Bool {
        guard let p = processBundleID, !p.isEmpty else { return false }
        if p == bundleID { return true }
        if p.hasPrefix(bundleID + ".") { return true }
        if let aliases = bundleAliases[bundleID], aliases.contains(p) { return true }
        return false
    }

    // MARK: - Route construction

    private enum RouteError: Error, CustomStringConvertible {
        case osStatus(OSStatus, String)

        var description: String {
            switch self {
            case let .osStatus(status, op): return "\(op) failed (OSStatus \(status))"
            }
        }
    }

    private func check(_ status: OSStatus, _ operation: String) throws {
        guard status == noErr else { throw RouteError.osStatus(status, operation) }
    }

    private func buildRoute(bundleID: String, device: AudioOutputDevice, processObjectIDs: Set<AudioObjectID>) throws {
        let description = CATapDescription(stereoMixdownOfProcesses: Array(processObjectIDs))
        description.name = "Announcer tap: \(bundleID)"
        description.muteBehavior = .mutedWhenTapped
        description.isPrivate = true

        var tapID = AudioObjectID(kAudioObjectUnknown)
        try check(AudioHardwareCreateProcessTap(description, &tapID), "AudioHardwareCreateProcessTap")

        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Announcer: \(bundleID)",
            kAudioAggregateDeviceUIDKey: Self.aggregateUIDPrefix + UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceMainSubDeviceKey: device.uid,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: device.uid]
            ],
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapUIDKey: description.uuid.uuidString,
                    kAudioSubTapDriftCompensationKey: true
                ]
            ]
        ]

        var aggregateID = AudioObjectID(kAudioObjectUnknown)
        do {
            try check(
                AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &aggregateID),
                "AudioHardwareCreateAggregateDevice"
            )
        } catch {
            AudioHardwareDestroyProcessTap(tapID)
            throw error
        }

        var procID: AudioDeviceIOProcID?
        let ioQueue = DispatchQueue(label: "com.johnvey.announcer.io.\(bundleID)", qos: .userInteractive)
        do {
            try check(
                AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, ioQueue) { _, inInputData, _, outOutputData, _ in
                    Self.render(input: inInputData, output: outOutputData)
                },
                "AudioDeviceCreateIOProcIDWithBlock"
            )
            try check(AudioDeviceStart(aggregateID, procID), "AudioDeviceStart")
        } catch {
            if let procID { AudioDeviceDestroyIOProcID(aggregateID, procID) }
            AudioHardwareDestroyAggregateDevice(aggregateID)
            AudioHardwareDestroyProcessTap(tapID)
            throw error
        }

        routes[bundleID] = Route(
            bundleID: bundleID,
            deviceUID: device.uid,
            processObjectIDs: processObjectIDs,
            tapID: tapID,
            aggregateID: aggregateID,
            procID: procID!
        )
        log.info("Routing \(bundleID, privacy: .public) -> \(device.name, privacy: .public)")
    }

    private func teardownRoute(bundleID: String) {
        guard let route = routes.removeValue(forKey: bundleID) else { return }
        AudioDeviceStop(route.aggregateID, route.procID)
        AudioDeviceDestroyIOProcID(route.aggregateID, route.procID)
        AudioHardwareDestroyAggregateDevice(route.aggregateID)
        AudioHardwareDestroyProcessTap(route.tapID)
        log.info("Stopped routing \(bundleID, privacy: .public)")
    }

    // MARK: - Realtime render

    /// Copies the tap's (stereo, Float32) input buffers into the output device's buffers.
    /// Runs on the realtime IO thread: no allocation, no locks, no ObjC.
    private static func render(input: UnsafePointer<AudioBufferList>, output: UnsafeMutablePointer<AudioBufferList>) {
        let outABL = UnsafeMutableAudioBufferListPointer(output)
        for buffer in outABL {
            if let data = buffer.mData {
                memset(data, 0, Int(buffer.mDataByteSize))
            }
        }

        let inABL = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        guard let inBuffer = inABL.first(where: { $0.mNumberChannels > 0 && $0.mData != nil }),
              let inData = inBuffer.mData else { return }

        let inChannels = Int(inBuffer.mNumberChannels)
        let inFrames = Int(inBuffer.mDataByteSize) / (MemoryLayout<Float32>.size * inChannels)
        let inSamples = inData.assumingMemoryBound(to: Float32.self)

        for buffer in outABL {
            guard let outData = buffer.mData, buffer.mNumberChannels > 0 else { continue }
            let outChannels = Int(buffer.mNumberChannels)
            let outFrames = Int(buffer.mDataByteSize) / (MemoryLayout<Float32>.size * outChannels)
            let outSamples = outData.assumingMemoryBound(to: Float32.self)
            let frames = min(inFrames, outFrames)
            let channels = min(outChannels, 2)
            for frame in 0..<frames {
                for channel in 0..<channels {
                    let inChannel = min(channel, inChannels - 1)
                    outSamples[frame * outChannels + channel] = inSamples[frame * inChannels + inChannel]
                }
            }
        }
    }
}
