import Foundation

struct GoLinkStore {
    private let key = "goLinks"
    private let defaults = UserDefaults.standard

    func load() -> [String: String] {
        guard let raw = defaults.dictionary(forKey: key) else { return [:] }
        return raw.compactMapValues { $0 as? String }
    }

    func save(_ links: [String: String]) {
        defaults.set(links, forKey: key)
    }

    func alias(for appName: String) -> String {
        load()[appName] ?? Self.defaultAlias(for: appName)
    }

    func setAlias(_ alias: String, for appName: String) {
        var links = load()
        links[appName] = alias.isEmpty ? Self.defaultAlias(for: appName) : alias
        save(links)
    }

    /// "nudge:native" → "nudge-native": a colon in go/nudge:native reads as a URL scheme
    /// or port to half the tools that see it.
    static func defaultAlias(for appName: String) -> String {
        appName.lowercased().replacingOccurrences(of: ":", with: "-")
    }
}
