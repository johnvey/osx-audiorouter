import AppKit
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let engine = RouteEngine()
    private var statusItem: NSStatusItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            let image = NSImage(systemSymbolName: "hifispeaker.2", accessibilityDescription: "Announcer")
            image?.isTemplate = true
            button.image = image
        }
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        engine.onChange = { [weak self] in
            self?.updateStatusIcon()
        }
        engine.start()
        updateStatusIcon()
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Destroying the taps unmutes the apps' normal output.
        engine.teardownAll()
    }

    private func updateStatusIcon() {
        guard let button = statusItem.button else { return }
        let active = engine.rules.keys.contains { engine.isRouteActive(bundleID: $0) }
        let symbol = active ? "hifispeaker.2.fill" : "hifispeaker.2"
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Announcer")
        image?.isTemplate = true
        button.image = image
    }

    // MARK: - Menu construction

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let devices = AudioDevices.outputDevices().sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        let apps = candidateApps()

        let header = NSMenuItem(title: "Route Apps to Output Devices", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        if apps.isEmpty {
            let empty = NSMenuItem(title: "No running apps", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        }

        for app in apps {
            let item = NSMenuItem(title: app.name, action: nil, keyEquivalent: "")
            if let icon = app.icon {
                let small = icon.copy() as! NSImage
                small.size = NSSize(width: 16, height: 16)
                item.image = small
            }
            let ruleUID = engine.rules[app.bundleID]
            if let ruleUID {
                let deviceName = devices.first { $0.uid == ruleUID }?.name ?? "missing device"
                let live = engine.isRouteActive(bundleID: app.bundleID)
                item.subtitle = live ? "→ \(deviceName)" : "→ \(deviceName) (idle)"
            }
            item.submenu = deviceSubmenu(for: app, devices: devices, ruleUID: ruleUID)
            menu.addItem(item)
        }

        menu.addItem(.separator())

        let loginItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin(_:)), keyEquivalent: "")
        loginItem.target = self
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(loginItem)

        let quitItem = NSMenuItem(title: "Quit Announcer", action: #selector(quit(_:)), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }

    private func deviceSubmenu(for app: CandidateApp, devices: [AudioOutputDevice], ruleUID: String?) -> NSMenu {
        let submenu = NSMenu()

        let systemDefault = NSMenuItem(title: "System Default", action: #selector(selectDevice(_:)), keyEquivalent: "")
        systemDefault.target = self
        systemDefault.state = ruleUID == nil ? .on : .off
        systemDefault.representedObject = RouteSelection(bundleID: app.bundleID, deviceUID: nil)
        submenu.addItem(systemDefault)
        submenu.addItem(.separator())

        for device in devices {
            let item = NSMenuItem(title: device.name, action: #selector(selectDevice(_:)), keyEquivalent: "")
            item.target = self
            item.state = ruleUID == device.uid ? .on : .off
            item.representedObject = RouteSelection(bundleID: app.bundleID, deviceUID: device.uid)
            submenu.addItem(item)
        }

        // A rule can point at a device that is currently unplugged; still show it so it can be cleared.
        if let ruleUID, !devices.contains(where: { $0.uid == ruleUID }) {
            let item = NSMenuItem(title: "Unavailable device", action: nil, keyEquivalent: "")
            item.isEnabled = false
            item.state = .on
            submenu.addItem(item)
        }

        return submenu
    }

    private final class RouteSelection: NSObject {
        let bundleID: String
        let deviceUID: String?
        init(bundleID: String, deviceUID: String?) {
            self.bundleID = bundleID
            self.deviceUID = deviceUID
        }
    }

    private struct CandidateApp {
        let bundleID: String
        let name: String
        let icon: NSImage?
    }

    /// Regular (Dock-visible) running apps, plus any app that has a saved rule.
    private func candidateApps() -> [CandidateApp] {
        var seen = Set<String>()
        var apps: [CandidateApp] = []
        let ownBundleID = Bundle.main.bundleIdentifier

        for running in NSWorkspace.shared.runningApplications {
            guard running.activationPolicy == .regular,
                  let bundleID = running.bundleIdentifier,
                  bundleID != ownBundleID,
                  !seen.contains(bundleID) else { continue }
            seen.insert(bundleID)
            apps.append(CandidateApp(bundleID: bundleID, name: running.localizedName ?? bundleID, icon: running.icon))
        }

        for bundleID in engine.rules.keys where !seen.contains(bundleID) {
            seen.insert(bundleID)
            apps.append(CandidateApp(bundleID: bundleID, name: "\(bundleID) (not running)", icon: nil))
        }

        return apps.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    // MARK: - Actions

    @objc private func selectDevice(_ sender: NSMenuItem) {
        guard let selection = sender.representedObject as? RouteSelection else { return }
        engine.setRule(bundleID: selection.bundleID, deviceUID: selection.deviceUID)
    }

    @objc private func toggleLaunchAtLogin(_ sender: NSMenuItem) {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    @objc private func quit(_ sender: NSMenuItem) {
        NSApp.terminate(nil)
    }
}
