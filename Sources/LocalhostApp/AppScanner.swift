import Foundation

struct AppScanner: Sendable {
    let portfolioRoot: URL

    private let excluded: Set<String> = ["dev-dashboard", "localhost-3000", ".git", "node_modules"]

    struct ScannedApp: Sendable {
        let name: String                // row key: folder, or "folder:instance" for multi-target projects
        let folder: String              // project directory under the portfolio root
        let instance: String?           // declared target label when the folder has several
        let scriptPort: Int?
        let devScript: String?
        let devScriptName: String?      // npm script name to run for the frontend (dev or dev:frontend)
        let sniffScript: String?        // devScript + expanded `npm run X` references, for framework detection only
        let backendKind: BackendKind?   // Convex / Supabase, if the project has one
        let backendBundled: Bool        // the frontend dev script already starts the backend
        let backendNeedsLocal: Bool     // backend runs as a local process (vs a cloud connection)
        let backendCommand: String?     // sidecar command to spawn when the backend isn't bundled
        let runTarget: RunTarget?       // declared in openport.json; nil = inferred from package.json
        let framework: String?          // declared framework, overrides dev-script sniffing
        let cacheDirs: [String]         // declared build caches to wipe on a clean restart
        /// A declared port is the truth, not a hint — it overwrites a stored auto-assignment.
        var declaredPort: Int? { runTarget?.port }
    }

    /// Returns one entry per runnable thing: a plain project is one row, a project whose
    /// openport.json declares N run targets is N rows sharing a folder.
    func scanWithPorts() -> [ScannedApp] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: portfolioRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        // Folders sort alphabetically; a folder's instances keep their openport.json order, so
        // the first declared target is listed (and treated) first.
        let groups = entries.compactMap { url -> [ScannedApp]? in
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { return nil }
            let folder = url.lastPathComponent
            guard !excluded.contains(folder) else { return nil }

            let pkgPath = url.appendingPathComponent("package.json")
            guard fm.fileExists(atPath: pkgPath.path),
                  let data = try? Data(contentsOf: pkgPath),
                  let pkg = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return nil }
            let scripts = (pkg["scripts"] as? [String: Any]) ?? [:]

            let config = readConfig(in: url)
            let targets = config?.runTargets ?? []

            // Prefer "dev"; fall back to "dev:frontend" for split frontend/backend setups.
            // A project that declares its own run targets doesn't need either.
            let devScriptName: String?
            let devScript: String?
            if let s = scripts["dev"] as? String {
                devScriptName = "dev"
                devScript = s
            } else if let s = scripts["dev:frontend"] as? String {
                devScriptName = "dev:frontend"
                devScript = s
            } else if !targets.isEmpty {
                devScriptName = nil
                devScript = nil
            } else {
                return nil
            }
            let sniffScript = devScript.map { Self.expandScriptReferences($0, scripts: scripts) }

            // An explicit backend declaration wins outright. Otherwise we sniff, as before.
            let projectBackend = config?.backend
                ?? detectBackend(in: url, devScript: devScript ?? "", scripts: scripts)

            func entry(name: String, instance: String?, target: DeclaredTarget?) -> ScannedApp {
                // A target can override the project's backend and caches: nudge's native stack
                // talks to a cloud deployment and builds into .next-native, its hubspot stack
                // runs a local backend and builds into .next. Clean-restarting one must not wipe
                // the cache the other is serving from.
                let backend = target?.backend ?? projectBackend
                return ScannedApp(
                    name: name,
                    folder: folder,
                    instance: instance,
                    scriptPort: target?.target.port ?? devScript.flatMap(extractPort),
                    devScript: devScript,
                    devScriptName: devScriptName,
                    sniffScript: sniffScript,
                    backendKind: backend.kind,
                    backendBundled: backend.bundled,
                    backendNeedsLocal: backend.needsLocal,
                    backendCommand: backend.command,
                    runTarget: target?.target,
                    framework: config?.framework,
                    cacheDirs: target?.caches ?? config?.cacheDirs ?? []
                )
            }

            if targets.count > 1 {
                return targets.map { entry(name: "\(folder):\($0.target.name)", instance: $0.target.name, target: $0) }
            }
            return [entry(name: folder, instance: nil, target: targets.first)]
        }
        return groups.sorted { $0[0].folder < $1[0].folder }.flatMap { $0 }
    }

    private struct BackendInfo {
        var kind: BackendKind?
        var bundled: Bool
        var needsLocal: Bool
        var command: String?
    }

    private struct DeclaredTarget {
        var target: RunTarget
        var backend: BackendInfo?
        var caches: [String]?
    }

    private struct ProjectConfig {
        var runTargets: [DeclaredTarget]
        var backend: BackendInfo?
        var framework: String?
        var cacheDirs: [String]
    }

    /// Reads `openport.json` from a project root. This is how a project stops us guessing:
    /// once a dev command hides behind a launcher script (`node scripts/dev.mjs`), we can't
    /// tell what port it binds or how many processes it starts, and every heuristic we'd add
    /// is another thing that silently gets it wrong.
    ///
    /// ```json
    /// {
    ///   "run": [
    ///     { "name": "hubspot", "command": "npm run dev:hubspot", "port": 3012, "caches": [".next"] },
    ///     { "name": "native",  "command": "npm run dev:native",  "port": 3013, "caches": [".next-native"],
    ///       "backend": { "kind": "convex", "local": false } }
    ///   ],
    ///   "backend": { "kind": "convex", "bundled": true, "local": true },
    ///   "framework": "next"
    /// }
    /// ```
    ///
    /// One target → one row named after the folder. Several → one row each ("nudge:hubspot"),
    /// independently runnable. `backend` and `caches` inside a target override the project's.
    /// Every key is optional — a malformed file falls back to the old sniffing rather than
    /// hiding the project.
    private func readConfig(in url: URL) -> ProjectConfig? {
        let path = url.appendingPathComponent("openport.json")
        guard let data = try? Data(contentsOf: path),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        var seenNames = Set<String>()
        let targets: [DeclaredTarget] = (root["run"] as? [[String: Any]] ?? []).compactMap { entry in
            guard let command = (entry["command"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !command.isEmpty
            else { return nil }
            let declared = (entry["name"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            var name = (declared?.isEmpty == false ? declared! : CommandLabel.label(for: command))
            // Names key rows, ports and the process table — a duplicate would make two rows
            // fight over one process. Disambiguate rather than drop the target.
            if seenNames.contains(name) { name += "-\(seenNames.count + 1)" }
            seenNames.insert(name)
            return DeclaredTarget(
                target: RunTarget(name: name, command: command,
                                  port: (entry["port"] as? Int).flatMap { PortStore.isValid($0) ? $0 : nil }),
                backend: (entry["backend"] as? [String: Any]).map(Self.parseBackend),
                caches: entry["caches"] as? [String]
            )
        }

        return ProjectConfig(
            runTargets: targets,
            backend: (root["backend"] as? [String: Any]).map(Self.parseBackend),
            framework: (root["framework"] as? String)?.lowercased(),
            cacheDirs: (root["caches"] as? [String]) ?? []
        )
    }

    private static func parseBackend(_ raw: [String: Any]) -> BackendInfo {
        let kind = (raw["kind"] as? String).flatMap { BackendKind(rawValue: $0.lowercased()) }
        let command = (raw["command"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return BackendInfo(
            kind: kind,
            bundled: raw["bundled"] as? Bool ?? false,
            // Default true only when a kind is declared: saying "convex" and nothing else
            // means a real backend exists, and claiming it's cloud-hosted would be a guess.
            needsLocal: raw["local"] as? Bool ?? (kind != nil),
            command: (command?.isEmpty == false) ? command : nil
        )
    }

    /// Works out whether a project depends on a Convex/Supabase backend, whether its
    /// frontend `dev` script already launches it, whether that backend runs as a local
    /// process, and (if we must start it ourselves) the command to run.
    private func detectBackend(in url: URL, devScript: String, scripts: [String: Any]) -> BackendInfo {
        let fm = FileManager.default
        let hasConvex = fm.fileExists(atPath: url.appendingPathComponent("convex").path)
        let hasSupabase = fm.fileExists(atPath: url.appendingPathComponent("supabase").path)

        let kind: BackendKind? = hasConvex ? .convex : (hasSupabase ? .supabase : nil)
        guard let kind else { return BackendInfo(kind: nil, bundled: false, needsLocal: false, command: nil) }

        let env = readEnv(in: url)

        // We only run a backend you've actually declared via a `dev:backend` script. We never
        // invent `npx convex dev` / `supabase start` — if a local backend has nothing to start
        // it and dev doesn't bundle it, we warn instead of magicking a process into existence.
        let hasBackendScript = scripts["dev:backend"] != nil

        switch kind {
        case .convex:
            // A local open-source backend (CONVEX_DEPLOYMENT local:/anonymous:, or a localhost
            // URL) runs as a process we must launch. Cloud dev/prod deployments need no local
            // process — the frontend talks straight to the *.convex.cloud URL and data works
            // without `convex dev` (that watcher only hot-pushes code changes, which dev can bundle).
            let convexURL = env["NEXT_PUBLIC_CONVEX_URL"] ?? env["CONVEX_URL"] ?? ""
            let deployment = env["CONVEX_DEPLOYMENT"] ?? ""
            let needsLocal = convexURL.contains("localhost") || convexURL.contains("127.0.0.1")
                || deployment.hasPrefix("local:") || deployment.hasPrefix("anonymous:")
            let bundled = devScript.contains("convex dev") || devScript.contains("convex ")
            let command = (needsLocal && !bundled && hasBackendScript) ? "npm run dev:backend" : nil
            return BackendInfo(kind: .convex, bundled: bundled, needsLocal: needsLocal, command: command)

        case .supabase:
            // Cloud Supabase (https URL) needs no local process — only local docker
            // (URL on localhost) does.
            let url = (env["SUPABASE_URL"] ?? env["NEXT_PUBLIC_SUPABASE_URL"] ?? "")
            let needsLocal = url.contains("localhost") || url.contains("127.0.0.1")
            let bundled = devScript.contains("supabase start") || devScript.contains("supabase ")
            let command = (needsLocal && !bundled && hasBackendScript) ? "npm run dev:backend" : nil
            return BackendInfo(kind: .supabase, bundled: bundled, needsLocal: needsLocal, command: command)
        }
    }

    /// Shallow parse of .env.local then .env into a key→value map. First file wins.
    private func readEnv(in url: URL) -> [String: String] {
        var result: [String: String] = [:]
        for file in [".env.local", ".env"] {
            let path = url.appendingPathComponent(file)
            guard let text = try? String(contentsOf: path, encoding: .utf8) else { continue }
            for rawLine in text.split(separator: "\n") {
                let line = rawLine.trimmingCharacters(in: .whitespaces)
                guard !line.hasPrefix("#"), let eq = line.firstIndex(of: "=") else { continue }
                let key = String(line[..<eq]).trimmingCharacters(in: .whitespaces)
                var value = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
                // Strip surrounding quotes and any trailing inline comment.
                if let hash = value.firstIndex(of: "#") { value = String(value[..<hash]).trimmingCharacters(in: .whitespaces) }
                value = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                if result[key] == nil { result[key] = value }
            }
        }
        return result
    }

    /// Appends the bodies of any `npm run X` scripts a dev script references, so framework
    /// sniffing can see through one level of indirection. A wrapper like
    /// `convex dev --start "npm run dev:frontend"` says nothing about the framework — the
    /// referenced script (`"dev:frontend": "vite"`) does. The result is for detection only;
    /// it is never executed.
    static func expandScriptReferences(_ script: String, scripts: [String: Any], depth: Int = 0) -> String {
        guard depth < 3,
              let regex = try? NSRegularExpression(pattern: #"npm run ([A-Za-z0-9:._-]+)"#)
        else { return script }
        var result = script
        let range = NSRange(script.startIndex..., in: script)
        for match in regex.matches(in: script, range: range) {
            guard let nameRange = Range(match.range(at: 1), in: script),
                  let referenced = scripts[String(script[nameRange])] as? String
            else { continue }
            result += " " + expandScriptReferences(referenced, scripts: scripts, depth: depth + 1)
        }
        return result
    }

    /// Parses -p 3001 / --port 3001 / --port=3001 from a dev script string.
    private func extractPort(from script: String) -> Int? {
        let pattern = #"(?:-p|--port[= ])(\d{4,5})"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: script, range: NSRange(script.startIndex..., in: script)),
              let range = Range(match.range(at: 1), in: script),
              let port = Int(script[range]), PortStore.isValid(port)
        else { return nil }
        return port
    }
}
