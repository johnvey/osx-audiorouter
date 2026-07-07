import Foundation

/// Persists routing rules (app bundle ID -> output device UID) as JSON in Application Support.
final class RuleStore {
    private let fileURL: URL

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Announcer", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("rules.json")
    }

    func load() -> [String: String] {
        guard let data = try? Data(contentsOf: fileURL),
              let rules = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return rules
    }

    func save(_ rules: [String: String]) {
        guard let data = try? JSONEncoder().encode(rules) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
