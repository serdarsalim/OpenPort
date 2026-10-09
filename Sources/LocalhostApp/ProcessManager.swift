import Foundation

@MainActor
final class ProcessManager {
    private var running: [String: Process] = [:]
    private var backends: [String: [Process]] = [:]
    private var stopping: Set<String> = []
    private var logBuffers: [String: LogBuffer] = [:]
    private(set) var crashLogs: [String: String] = [:]  // name → last stderr on unexpected exit

    var onTerminated: ((String) -> Void)?

    func start(
        name: String,
        port: Int,
        in directory: URL,
        devScript: String? = nil,
        devScriptName: String? = nil,
        sniffScript: String? = nil,
        primaryCommand: String? = nil,
        backendCommand: String? = nil,
        convexCompat: Bool = false,
        bindHost: Bool = false,
        declaredFramework: String? = nil
    ) {
        guard !(running[name]?.isRunning == true) else { return }

        let framework = Self.detectFramework(devScript: sniffScript ?? devScript, declared: declaredFramework)
        let env = baseEnvironment(port: port, directory: directory, convexCompat: convexCompat,
                                  bindHost: bindHost, framework: framework)
        let scriptName = devScriptName ?? "dev"

        // When bindHost is on, expose the dev server on all interfaces so phones on the LAN
        // can reach it. The lever is framework-specific: Vite/Next take a flag, CRA reads HOST.
        let base: String
        let viaNpm: Bool
        let declared: Bool
        if let primaryCommand {
            // Declared in openport.json — run it exactly as written. We don't patch its port or
            // graft on host flags: the project already stated what it wants, and rewriting a
            // command we can't parse (a launcher script, a wrapper) is how we'd break it.
            base = primaryCommand; viaNpm = false; declared = true
        } else if let script = devScript, script.contains("-p") || script.contains("--port") {
            base = patchPort(in: script, to: port); viaNpm = false; declared = false
        } else if let script = devScript, framework == .vite {
            // Vite is the one framework that ignores PORT/VITE_PORT outright — the port must
            // arrive as a CLI flag or it boots on 5173 while we watch the assigned port forever.
            // A wrapped script (`convex dev --start "npm run dev:frontend"`) can't take the flag
            // through `npm run dev --`, so we run the script body directly and thread the flag
            // into the inner command. node_modules/.bin is already on PATH, so the semantics match.
            if script.contains("--start") {
                base = Self.applyPortBinding(to: script, framework: .vite, viaNpm: false, port: port)
                viaNpm = false
            } else {
                base = Self.applyPortBinding(to: "npm run \(scriptName)", framework: .vite, viaNpm: true, port: port)
                viaNpm = true
            }
            declared = false
        } else {
            base = "npm run \(scriptName)"; viaNpm = true; declared = false
        }
        let shouldBindHost = bindHost && !declared
        let command = "exec \(shouldBindHost ? Self.applyHostBinding(to: base, framework: framework, viaNpm: viaNpm) : base)"

        // Clear any previous crash log when restarting.
        crashLogs.removeValue(forKey: name)

        let buffer = LogBuffer()
        logBuffers[name] = buffer

        let frontend = makeProcess(directory: directory, env: env, command: command, logBuffer: buffer)
        frontend.terminationHandler = { [weak self, name] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let unexpected = !self.stopping.contains(name)
                self.stopping.remove(name)
                self.running.removeValue(forKey: name)
                for sidecar in self.backends.removeValue(forKey: name) ?? [] where sidecar.isRunning {
                    SystemClient.killTree(pid: sidecar.processIdentifier)
                }
                if unexpected {
                    if let log = self.logBuffers[name]?.snapshot() {
                        self.crashLogs[name] = log
                    }
                    self.logBuffers.removeValue(forKey: name)
                    self.onTerminated?(name)
                } else {
                    self.logBuffers.removeValue(forKey: name)
                }
            }
        }

        // A backend that isn't bundled into the dev script (`npm run dev:backend`) runs beside
        // the frontend and dies with it. It must not inherit the frontend's PORT.
        if let backendCommand {
            var backendEnv = env
            backendEnv.removeValue(forKey: "PORT")
            backendEnv.removeValue(forKey: "VITE_PORT")
            let process = makeProcess(directory: directory, env: backendEnv,
                                      command: "exec \(backendCommand)", logBuffer: buffer)
            process.terminationHandler = { [weak self, name] finished in
                Task { @MainActor [weak self] in
                    self?.backends[name]?.removeAll { $0 === finished }
                    if self?.backends[name]?.isEmpty == true { self?.backends.removeValue(forKey: name) }
                }
            }
            try? process.run()
            backends[name, default: []].append(process)
        }

        do {
            try frontend.run()
        } catch {
            // A spawn that never happens must not leave the row "starting" forever. Report it
            // through the same path as a crash so the row shows why.
            for backend in backends.removeValue(forKey: name) ?? [] where backend.isRunning {
                SystemClient.killTree(pid: backend.processIdentifier)
            }
            logBuffers.removeValue(forKey: name)
            crashLogs[name] = "OpenPort couldn't launch the process: \(error.localizedDescription)\n\(command)"
            onTerminated?(name)
            return
        }
        running[name] = frontend
    }

    func stop(name: String) {
        stopping.insert(name)
        crashLogs.removeValue(forKey: name)
        if let proc = running[name] { SystemClient.killTree(pid: proc.processIdentifier) }
        running.removeValue(forKey: name)
        logBuffers.removeValue(forKey: name)
        for sidecar in backends.removeValue(forKey: name) ?? [] where sidecar.isRunning {
            SystemClient.killTree(pid: sidecar.processIdentifier)
        }
    }

    func stopAll() {
        for name in running.keys { stopping.insert(name) }
        for process in running.values where process.isRunning {
            SystemClient.killTree(pid: process.processIdentifier)
        }
        for process in backends.values.flatMap({ $0 }) where process.isRunning {
            SystemClient.killTree(pid: process.processIdentifier)
        }
        running.removeAll()
        backends.removeAll()
        logBuffers.removeAll()
        crashLogs.removeAll()
    }

    /// Synchronous nuke for app shutdown. SIGTERM → 500ms wait → SIGKILL, blocking briefly so
    /// children actually die before we exit (otherwise they reparent to launchd as orphans).
    func nukeAllSync(alsoKilling extraTrees: [Int32] = []) {
        let pids = (running.values.map(\.processIdentifier)
            + backends.values.flatMap { $0 }.map(\.processIdentifier)
            + extraTrees)
            .filter { $0 > 0 }
        for name in running.keys { stopping.insert(name) }
        SystemClient.killTreesSync(pids: pids)
    }

    func isRunning(name: String) -> Bool {
        running[name]?.isRunning == true
    }

    func isBackendRunning(name: String) -> Bool {
        backends[name]?.contains { $0.isRunning } == true
    }

    func crashLog(for name: String) -> String? {
        crashLogs[name]
    }

    /// Live log snapshot (stdout + stderr, line-merged) for a running app.
    func liveLog(for name: String) -> String? {
        logBuffers[name]?.snapshot()
    }

    func clearLog(for name: String) {
        logBuffers[name]?.clear()
    }

    /// Frameworks we know how to expose on the LAN. `unknown` falls back to the HOST env var.
    enum Framework { case next, vite, cra, unknown }

    /// A declared framework (openport.json) wins — a project whose dev command is
    /// `node scripts/dev.mjs` gives the sniffer nothing to go on, and guessing `.unknown`
    /// silently turns clean-restart into a plain restart.
    static func detectFramework(devScript: String?, declared: String? = nil) -> Framework {
        switch declared {
        case "next":                       return .next
        case "vite", "sveltekit", "svelte": return .vite
        case "cra", "react-scripts":       return .cra
        default: break
        }
        guard let s = devScript?.lowercased() else { return .unknown }
        if s.contains("next") { return .next }
        if s.contains("vite") { return .vite }
        if s.contains("react-scripts") { return .cra }
        return .unknown
    }

    /// Build caches a framework's dev server reuses between runs, relative to the project dir.
    /// A corrupt or oversized cache is the usual reason `npm run dev` pegs CPU and never serves —
    /// a plain Stop→Run reuses it and wedges again, so a clean restart wipes these first.
    nonisolated static func cacheDirs(for framework: Framework) -> [String] {
        switch framework {
        case .next:    return [".next"]
        case .vite:    return ["node_modules/.vite", ".svelte-kit"]  // SvelteKit runs on Vite
        case .cra:     return ["node_modules/.cache"]
        case .unknown: return []
        }
    }

    /// Delete a framework's build caches off the main thread. No-op for unknown frameworks or
    /// caches that don't exist. Safe — these are regenerated on the next dev build.
    nonisolated static func clearCaches(in directory: URL, framework: Framework, extra: [String] = []) {
        let fm = FileManager.default
        // A declared cache list REPLACES the framework default. nudge's two stacks build into
        // .next and .next-native; clean-restarting native must wipe .next-native only — the
        // framework default (.next) is the cache its hubspot sibling is serving from.
        let relative = extra.isEmpty ? cacheDirs(for: framework) : Array(Set(extra))
        for rel in relative where !rel.isEmpty && !rel.hasPrefix("/") && !rel.contains("..") {
            let url = directory.appendingPathComponent(rel)
            if fm.fileExists(atPath: url.path) {
                try? fm.removeItem(at: url)
            }
        }
    }

    /// When the frontend runs inside a wrapper like `convex dev --start 'next dev …'` or
    /// `convex dev --start "npm run dev:frontend"`, flags belong on the inner command, not
    /// the wrapper — otherwise Convex (or whatever launches the dev server) receives them
    /// and aborts. Returns the quoted inner command's range, or nil when there's no wrapper.
    private static func wrappedInnerRange(of command: String) -> Range<String.Index>? {
        for quote: Character in ["'", "\""] {
            if let open = command.range(of: "--start \(quote)"),
               let close = command[open.upperBound...].firstIndex(of: quote) {
                return open.upperBound..<close
            }
        }
        return nil
    }

    /// Append a flag, threading it through `npm run … --` when the command is an npm script.
    /// If a passthrough `--` is already present, a second one would land in the script's
    /// positional args — append the flag to the existing group instead.
    private static func appendFlag(_ flag: String, to command: String, viaNpm: Bool) -> String {
        if viaNpm && !command.contains(" -- ") {
            return "\(command) -- \(flag)"
        }
        return "\(command) \(flag)"
    }

    /// Append the right host flag for the framework. Vite and Next take a CLI flag (passed
    /// through `npm run … --` when invoked via npm); CRA/unknown rely on the HOST env var.
    static func applyHostBinding(to command: String, framework: Framework, viaNpm: Bool) -> String {
        if let innerRange = wrappedInnerRange(of: command) {
            let inner = String(command[innerRange])
            let patched = applyHostBinding(to: inner, framework: framework,
                                           viaNpm: inner.hasPrefix("npm run "))
            return command.replacingCharacters(in: innerRange, with: patched)
        }
        switch framework {
        case .vite:
            if command.contains("--host") { return command }
            return appendFlag("--host", to: command, viaNpm: viaNpm)
        case .next:
            if command.contains("-H ") || command.contains("--hostname") { return command }
            return appendFlag("-H 0.0.0.0", to: command, viaNpm: viaNpm)
        case .cra, .unknown:
            return command  // handled via HOST in the environment
        }
    }

    /// Append the port flag for frameworks that won't take it from the environment.
    /// Only Vite needs this (Next and CRA read PORT); `--strictPort` makes a collision fail
    /// loudly in the logs instead of silently drifting to the next free port.
    static func applyPortBinding(to command: String, framework: Framework, viaNpm: Bool, port: Int) -> String {
        if let innerRange = wrappedInnerRange(of: command) {
            let inner = String(command[innerRange])
            let patched = applyPortBinding(to: inner, framework: framework,
                                           viaNpm: inner.hasPrefix("npm run "), port: port)
            return command.replacingCharacters(in: innerRange, with: patched)
        }
        switch framework {
        case .vite:
            if command.contains("--port") { return command }
            return appendFlag("--port \(port) --strictPort", to: command, viaNpm: viaNpm)
        case .next, .cra, .unknown:
            return command  // PORT env is respected
        }
    }

    private func baseEnvironment(port: Int, directory: URL, convexCompat: Bool,
                                 bindHost: Bool = false, framework: Framework = .unknown) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PORT"] = "\(port)"
        env["VITE_PORT"] = "\(port)"
        // CRA's react-scripts and many webpack-based servers bind all interfaces when HOST is set.
        // Only set it for those — Vite/Next get a CLI flag instead, and some apps read process.env.HOST
        // for their own logic, so we don't clobber it needlessly.
        if bindHost, framework == .cra || framework == .unknown {
            env["HOST"] = "0.0.0.0"
        }
        let localBin = directory.appendingPathComponent("node_modules/.bin").path
        // A pinned (.nvmrc) or Convex-compatible Node goes ahead of the Homebrew default so
        // `node`/`npm`/`npx` resolve to the right version for this project.
        let nodeBin = NodeResolver.resolve(directory: directory, convexCompat: convexCompat)?.binDir
        let extraPaths = [localBin, nodeBin, "/opt/homebrew/bin", "/usr/local/bin"]
            .compactMap { $0 }
            .joined(separator: ":")
        env["PATH"] = "\(extraPaths):\(env["PATH"] ?? "/usr/bin:/bin")"
        return env
    }

    private func makeProcess(directory: URL, env: [String: String], command: String, logBuffer: LogBuffer?) -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", command]
        process.currentDirectoryURL = directory
        process.environment = env

        if let buffer = logBuffer {
            let outPipe = Pipe()
            let errPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError = errPipe
            outPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
                buffer.append(text)
            }
            errPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
                buffer.append(text)
            }
        } else {
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
        }

        return process
    }

    private func patchPort(in script: String, to port: Int) -> String {
        var result = script
        let patterns = [
            (#"(-p\s+)\d{4,5}"#,       "$1\(port)"),
            (#"(--port=)\d{4,5}"#,      "$1\(port)"),
            (#"(--port\s+)\d{4,5}"#,    "$1\(port)")
        ]
        for (pattern, replacement) in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: replacement)
        }
        return result
    }
}

// Collects stdout + stderr lines in a ring buffer; thread-safe via NSLock.
final class LogBuffer: @unchecked Sendable {
    private var lines: [String] = []
    private let lock = NSLock()
    private let maxLines = 1000

    func append(_ text: String) {
        let incoming = LogBuffer.stripANSI(text).components(separatedBy: "\n").filter { !$0.isEmpty }
        lock.lock()
        lines.append(contentsOf: incoming)
        if lines.count > maxLines { lines.removeFirst(lines.count - maxLines) }
        lock.unlock()
    }

    // dev servers emit ANSI escapes (colors, cursor moves, hyperlinks). We render plain text,
    // so strip them at the source — otherwise the logs you read to debug a failed Run are
    // littered with [36m / [2m noise, and so is captured crash output.
    private static let ansiRegex = try? NSRegularExpression(
        pattern: "\\u001B(?:\\[[0-9;?]*[ -/]*[@-~]|\\][^\\u0007\\u001B]*(?:\\u0007|\\u001B\\\\))"
    )

    static func stripANSI(_ text: String) -> String {
        guard let regex = ansiRegex else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: "")
    }

    func snapshot() -> String? {
        lock.lock()
        let result = lines.isEmpty ? nil : lines.joined(separator: "\n")
        lock.unlock()
        return result
    }

    func clear() {
        lock.lock()
        lines.removeAll()
        lock.unlock()
    }
}
