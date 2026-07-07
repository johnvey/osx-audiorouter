import AudioToolbox
import CoreAudio
import Foundation
import os

/// Owns all active audio routes. For each rule whose app has live audio process objects, it
/// creates a process tap that mutes the app's normal output and an IO proc on a private aggregate
/// device that re-renders the tapped audio (with the rule's gain applied) to the target device —
/// the rule's device, or the system default device for volume-only rules.
///
/// Main-thread confined except for the realtime IO blocks.
final class RouteEngine {
    static let aggregateUIDPrefix = "com.johnvey.audiorouter.aggregate."

    private struct Route {
        let bundleID: String
        /// The resolved target device UID (for volume-only rules, the default device at build time).
        let deviceUID: String
        let processObjectIDs: Set<AudioObjectID>
        let tapID: AudioObjectID
        let aggregateID: AudioObjectID
        let procID: AudioDeviceIOProcID
        /// Written from the main thread, read from the realtime IO thread. Aligned 32-bit
        /// loads/stores are atomic on our targets, so no lock is needed.
        let gain: UnsafeMutablePointer<Float32>
    }

    /// Audio for some apps is produced by a differently-named helper process.
    private static let bundleAliases: [String: Set<String>] = [
        "com.apple.Safari": ["com.apple.WebKit.GPU"]
    ]

    private let log = Logger(subsystem: "com.johnvey.audiorouter", category: "RouteEngine")
    private let store = RuleStore()
    private var routes: [String: Route] = [:]
    private var reconcilePending = false
    private var savePending = false
    private var listenerBlock: AudioObjectPropertyListenerBlock?

    /// bundleID -> rule
    private(set) var rules: [String: Rule]

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
        var defaultAddr = propertyAddress(kAudioHardwarePropertyDefaultOutputDevice)
        AudioObjectAddPropertyListenerBlock(systemObjectID, &processAddr, DispatchQueue.main, block)
        AudioObjectAddPropertyListenerBlock(systemObjectID, &deviceAddr, DispatchQueue.main, block)
        AudioObjectAddPropertyListenerBlock(systemObjectID, &defaultAddr, DispatchQueue.main, block)
        reconcile()
    }

    /// True if audio is currently being actively re-routed for this app.
    func isRouteActive(bundleID: String) -> Bool {
        routes[bundleID] != nil
    }

    func setRule(bundleID: String, deviceUID: String?) {
        var rule = rules[bundleID] ?? Rule()
        rule.deviceUID = deviceUID
        applyRule(bundleID: bundleID, rule: rule)
        store.save(rules)
        reconcile()
    }

    /// Live-updates the gain of an active route; creates/removes the rule as needed.
    /// Cheap enough to call continuously from a slider drag.
    func setVolume(bundleID: String, volume: Float) {
        var rule = rules[bundleID] ?? Rule()
        rule.volume = min(max(volume, 0), 1)
        applyRule(bundleID: bundleID, rule: rule)
        if let route = routes[bundleID] {
            route.gain.pointee = rule.volume
        }
        scheduleSave()
        // Coalesced: builds the tap when a volume-only rule first appears, or tears it down
        // when the rule becomes a no-op. Gain changes on live routes never rebuild.
        scheduleReconcile()
    }

    private func applyRule(bundleID: String, rule: Rule) {
        if rule.isNoOp {
            rules.removeValue(forKey: bundleID)
        } else {
            rules[bundleID] = rule
        }
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

    private func scheduleSave() {
        guard !savePending else { return }
        savePending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            self.savePending = false
            self.store.save(self.rules)
        }
    }

    private func reconcile() {
        let devices = AudioDevices.outputDevices()
        let processes = AudioProcesses.all()
        let defaultDevice = AudioDevices.defaultOutputDevice()

        for (bundleID, rule) in rules {
            let desired = Set(
                processes
                    .filter { Self.processMatches(rule: bundleID, processBundleID: $0.bundleID) }
                    .map(\.objectID)
            )
            let device: AudioOutputDevice?
            if let uid = rule.deviceUID {
                device = devices.first { $0.uid == uid }
            } else {
                device = defaultDevice
            }

            if desired.isEmpty || device == nil {
                // App has no audio presence or device unplugged: no route needed right now.
                if routes[bundleID] != nil { teardownRoute(bundleID: bundleID) }
                continue
            }

            if let existing = routes[bundleID] {
                if existing.deviceUID == device!.uid && existing.processObjectIDs == desired {
                    existing.gain.pointee = rule.volume
                    continue
                }
                teardownRoute(bundleID: bundleID)
            }

            do {
                try buildRoute(bundleID: bundleID, device: device!, processObjectIDs: desired, gain: rule.volume)
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

    private func buildRoute(
        bundleID: String,
        device: AudioOutputDevice,
        processObjectIDs: Set<AudioObjectID>,
        gain: Float
    ) throws {
        let description = CATapDescription(stereoMixdownOfProcesses: Array(processObjectIDs))
        description.name = "AudioRouter tap: \(bundleID)"
        description.muteBehavior = .mutedWhenTapped
        description.isPrivate = true

        var tapID = AudioObjectID(kAudioObjectUnknown)
        try check(AudioHardwareCreateProcessTap(description, &tapID), "AudioHardwareCreateProcessTap")

        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "AudioRouter: \(bundleID)",
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

        let gainPointer = UnsafeMutablePointer<Float32>.allocate(capacity: 1)
        gainPointer.initialize(to: gain)

        var procID: AudioDeviceIOProcID?
        let ioQueue = DispatchQueue(label: "com.johnvey.audiorouter.io.\(bundleID)", qos: .userInteractive)
        do {
            try check(
                AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, ioQueue) { _, inInputData, _, outOutputData, _ in
                    Self.render(input: inInputData, output: outOutputData, gain: gainPointer.pointee)
                },
                "AudioDeviceCreateIOProcIDWithBlock"
            )
            try check(AudioDeviceStart(aggregateID, procID), "AudioDeviceStart")
        } catch {
            if let procID { AudioDeviceDestroyIOProcID(aggregateID, procID) }
            AudioHardwareDestroyAggregateDevice(aggregateID)
            AudioHardwareDestroyProcessTap(tapID)
            gainPointer.deallocate()
            throw error
        }

        routes[bundleID] = Route(
            bundleID: bundleID,
            deviceUID: device.uid,
            processObjectIDs: processObjectIDs,
            tapID: tapID,
            aggregateID: aggregateID,
            procID: procID!,
            gain: gainPointer
        )
        log.info("Routing \(bundleID, privacy: .public) -> \(device.name, privacy: .public) at gain \(gain, privacy: .public)")
    }

    private func teardownRoute(bundleID: String) {
        guard let route = routes.removeValue(forKey: bundleID) else { return }
        AudioDeviceStop(route.aggregateID, route.procID)
        // Blocks until in-flight IO callbacks finish, after which the gain pointer is unreferenced.
        AudioDeviceDestroyIOProcID(route.aggregateID, route.procID)
        AudioHardwareDestroyAggregateDevice(route.aggregateID)
        AudioHardwareDestroyProcessTap(route.tapID)
        route.gain.deallocate()
        log.info("Stopped routing \(bundleID, privacy: .public)")
    }

    // MARK: - Realtime render

    /// Copies the tap's (stereo, Float32) input buffers into the output device's buffers,
    /// applying the route's gain. Runs on the realtime IO thread: no allocation, no locks, no ObjC.
    private static func render(
        input: UnsafePointer<AudioBufferList>,
        output: UnsafeMutablePointer<AudioBufferList>,
        gain: Float32
    ) {
        let outABL = UnsafeMutableAudioBufferListPointer(output)
        for buffer in outABL {
            if let data = buffer.mData {
                memset(data, 0, Int(buffer.mDataByteSize))
            }
        }
        guard gain > 0 else { return }

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
                    outSamples[frame * outChannels + channel] = inSamples[frame * inChannels + inChannel] * gain
                }
            }
        }
    }
}
