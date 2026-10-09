import Foundation

struct PortStore {
    private let key = "appPorts"
    private let defaults = UserDefaults.standard

    func load() -> [String: Int] {
        guard let raw = defaults.dictionary(forKey: key) else { return [:] }
        // Out-of-range values (a typo'd 300001 saved before validation existed) are dropped
        // and reassigned rather than trusted.
        return raw.compactMapValues { $0 as? Int }.filter { Self.isValid($0.value) }
    }

    static func isValid(_ port: Int) -> Bool {
        (1...65535).contains(port)
    }

    func save(_ ports: [String: Int]) {
        defaults.set(ports, forKey: key)
    }

    /// Assigns ports to app names. For new apps, prefers the port hardcoded in
    /// their dev script (scriptPorts) over auto-incrementing from 3001.
    ///
    /// `declaredPorts` (from openport.json) outrank everything, including a port already in
    /// the store. A project that declares 3006 and runs its command verbatim genuinely binds
    /// 3006 — an auto-assigned 3001 left over from before the declaration would just make us
    /// watch the wrong port forever and report the app as crashed while it happily serves.
    func assign(
        to appNames: [String],
        scriptPorts: [String: Int] = [:],
        declaredPorts: [String: Int] = [:]
    ) -> [String: Int] {
        let stored = load()
        var ports = stored

        for (name, port) in declaredPorts where ports[name] != port {
            ports[name] = port
        }

        var used = Set(ports.values)
        var next = 3001

        for name in appNames {
            guard ports[name] == nil else { continue }

            if let hint = scriptPorts[name], !used.contains(hint) {
                // Respect the port hardcoded in the project's dev script
                ports[name] = hint
                used.insert(hint)
            } else {
                // Auto-assign next free port
                while used.contains(next) { next += 1 }
                ports[name] = next
                used.insert(next)
                next += 1
            }
        }
        // Writing UserDefaults on every 12s refresh fired didChangeNotification, which rebuilt
        // the menu bar menu a second time per refresh for nothing.
        if ports != stored { save(ports) }
        return ports
    }
}
