import Foundation

/// A per-app routing rule. `deviceUID == nil` means the app plays on the system default device;
/// such a rule is only meaningful if it also adjusts volume.
struct Rule: Codable, Equatable {
    var deviceUID: String?
    var volume: Float

    init(deviceUID: String? = nil, volume: Float = 1.0) {
        self.deviceUID = deviceUID
        self.volume = volume
    }

    /// True when the rule changes nothing and can be discarded.
    var isNoOp: Bool { deviceUID == nil && volume >= 0.999 }
}

/// Persists routing rules (app bundle ID -> Rule) as JSON in Application Support.
final class RuleStore {
    private let fileURL: URL

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("AudioRouter", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("rules.json")
    }

    func load() -> [String: Rule] {
        guard let data = try? Data(contentsOf: fileURL) else { return [:] }
        if let rules = try? JSONDecoder().decode([String: Rule].self, from: data) {
            return rules
        }
        // Legacy format: bundleID -> deviceUID string.
        if let legacy = try? JSONDecoder().decode([String: String].self, from: data) {
            return legacy.mapValues { Rule(deviceUID: $0) }
        }
        return [:]
    }

    func save(_ rules: [String: Rule]) {
        guard let data = try? JSONEncoder().encode(rules) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
