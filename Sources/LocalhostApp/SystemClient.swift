import AppKit
import Darwin

enum SystemClient {
    static func lanIPAddress() -> String {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else { return "localhost" }
        defer { freeifaddrs(ifaddr) }
        var ptr = ifaddr
        while let current = ptr {
            let iface = current.pointee
            if iface.ifa_addr.pointee.sa_family == UInt8(AF_INET),
               String(cString: iface.ifa_name) == "en0" {
                var addr = iface.ifa_addr.pointee
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                getnameinfo(&addr, socklen_t(iface.ifa_addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
                return String(cString: host)
            }
            ptr = current.pointee.ifa_next
        }
        return "localhost"
    }

    static func copyNetworkURL(port: Int) {
        let ip = lanIPAddress()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("http://\(ip):\(port)", forType: .string)
    }

    static func openTerminal(at url: URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", "Terminal", url.path]
        try? process.run()
    }

    static func openVSCode(at url: URL) {
        let code = "/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: code)
        process.arguments = [url.path]
        try? process.run()
    }

    static func openFinder(at url: URL) {
        NSWorkspace.shared.open(url)
    }

    static func openBrowser(port: Int) {
        guard let url = URL(string: "http://localhost:\(port)") else { return }
        NSWorkspace.shared.open(url)
    }

    static func isPortListening(_ port: Int, host: String = "127.0.0.1") -> Bool {
        // in_port_t(port) traps outside 0...65535 — one bad saved value crashed every launch.
        guard (1...65535).contains(port) else { return false }
        let target = host == "localhost" ? "127.0.0.1" : host
        let sock = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard sock >= 0 else { return false }
        defer { Darwin.close(sock) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(port).byteSwapped
        addr.sin_addr.s_addr = inet_addr(target)
        return withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
    }

    // Find all $USER-owned processes listening on TCP, mapped to cwd + command line.
    // Returns one entry per (pid, port). IPv4/IPv6 duplicates are collapsed.
    static func detectRunningServers() -> [DetectedServer] {
        let user = NSUserName()

        // Step 1: every $USER-owned listening TCP socket.
        // -a is critical: lsof selection flags are OR'd by default, so without
        // it this returns "all of $USER's open files" PLUS "all TCP listeners",
        // flooding output and blowing past the runCommand timeout.
        let listenLines = runCommand("/usr/sbin/lsof", ["-a", "-u", user, "-iTCP", "-sTCP:LISTEN", "-nP"])
            .components(separatedBy: "\n").dropFirst()
        var pidPorts: [(pid: Int32, port: Int, shortCmd: String)] = []
        var seen = Set<String>()
        for line in listenLines {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 9, let pid = Int32(parts[1]) else { continue }
            let shortCmd = String(parts[0])
            let nameField = String(parts[8])
            guard let port = nameField.split(separator: ":").last.flatMap({ Int($0) }) else { continue }
            let key = "\(pid):\(port)"
            if seen.contains(key) { continue }
            seen.insert(key)
            pidPorts.append((pid, port, shortCmd))
        }
        guard !pidPorts.isEmpty else { return [] }

        let uniquePids = Set(pidPorts.map { $0.pid })
        let pidList = uniquePids.map { "\($0)" }.joined(separator: ",")

        // Step 2: cwd per pid
        let cwdLines = runCommand("/usr/sbin/lsof", ["-p", pidList, "-a", "-d", "cwd", "-Fn"])
            .components(separatedBy: "\n")
        var cwds: [Int32: String] = [:]
        var currentPid: Int32 = 0
        for line in cwdLines {
            if line.hasPrefix("p"), let pid = Int32(line.dropFirst()) {
                currentPid = pid
            } else if line.hasPrefix("n"), currentPid != 0 {
                let dir = String(line.dropFirst())
                if !dir.isEmpty { cwds[currentPid] = dir }
            }
        }

        // Step 3: full command line per pid
        let commands = fetchCommands(for: pidList)

        return pidPorts.map { item in
            DetectedServer(
                pid: item.pid,
                port: item.port,
                directory: cwds[item.pid] ?? "",
                command: commands[item.pid] ?? item.shortCmd
            )
        }
    }

    private static func fetchCommands(for pidList: String) -> [Int32: String] {
        let output = runCommand("/bin/ps", ["-p", pidList, "-o", "pid=,command="])
        var result: [Int32: String] = [:]
        for raw in output.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard parts.count == 2, let pid = Int32(parts[0]) else { continue }
            result[pid] = String(parts[1])
        }
        return result
    }

    static func killPort(_ port: Int) {
        // LISTEN only. A bare `-i TCP:port` also matches every CLIENT connected to the port —
        // the browser tab you have open on localhost:3012 — so Stop used to SIGTERM the
        // browser's network process along with the dev server.
        let output = runCommand("/usr/sbin/lsof", ["-ti", "TCP:\(port)", "-sTCP:LISTEN"])
        for pidStr in output.components(separatedBy: .newlines) {
            let trimmed = pidStr.trimmingCharacters(in: .whitespaces)
            if let pid = Int32(trimmed), pid > 0 {
                killTree(pid: pid)
            }
        }
    }

    /// Recursively walks `pgrep -P` to collect every descendant PID.
    static func descendantPIDs(of pid: Int32) -> [Int32] {
        var result: Set<Int32> = []
        var queue: [Int32] = [pid]
        while let current = queue.popLast() {
            let out = runCommand("/usr/bin/pgrep", ["-P", "\(current)"], timeout: 2)
            for line in out.components(separatedBy: .newlines) {
                let t = line.trimmingCharacters(in: .whitespaces)
                if let child = Int32(t), child > 0, !result.contains(child) {
                    result.insert(child)
                    queue.append(child)
                }
            }
        }
        return Array(result)
    }

    /// SIGTERM the leader's process group + every descendant; SIGKILL fallback after 2s.
    /// Walks descendants so backend processes that don't bind a port (convex, esbuild) get reaped.
    static func killTree(pid: Int32) {
        guard pid > 0, pid != getpid() else { return }
        let descendants = descendantPIDs(of: pid)
        kill(-pid, SIGTERM)
        kill(pid, SIGTERM)
        for child in descendants { kill(child, SIGTERM) }
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
            // Re-walk before escalating: anything the tree spawned AFTER the snapshot
            // above (a convex push forking tsc, a Turbopack worker) escaped the SIGTERM
            // pass, and SIGKILLing only the stale list left it running headless —
            // orphaned typecheck processes from repeated Stop→Run cycles are how an
            // 8 GB machine ends up at load 600. Union, don't replace: a survivor whose
            // parent already died is invisible to a fresh walk but still in the snapshot.
            var doomed = Set(descendants)
            doomed.formUnion(descendantPIDs(of: pid))
            for child in descendants { doomed.formUnion(descendantPIDs(of: child)) }
            kill(-pid, SIGKILL)
            kill(pid, SIGKILL)
            for child in doomed { kill(child, SIGKILL) }
        }
    }

    /// Synchronous SIGTERM → 500ms wait → SIGKILL. For app shutdown where we can't rely on
    /// async dispatch firing before exit.
    static func killTreeSync(pid: Int32) {
        killTreesSync(pids: [pid])
    }

    /// Several trees at once, one shared 500ms grace period. Quitting with three servers up
    /// shouldn't cost 1.5s. Descendants are walked BEFORE the SIGTERM: launchers like
    /// `convex dev --start` and nudge's dev scripts spawn their children detached (own
    /// session), so a group kill on the leader never reaches them, and once the leader dies
    /// they reparent to launchd and a later walk can't find them either. That is exactly how
    /// quitting OpenPort used to leave `next dev` serving :3012 with nobody watching it.
    static func killTreesSync(pids: [Int32]) {
        let me = getpid()
        let leaders = pids.filter { $0 > 0 && $0 != me }
        guard !leaders.isEmpty else { return }
        var doomed = Set(leaders)
        for pid in leaders { doomed.formUnion(descendantPIDs(of: pid)) }
        doomed.remove(me)
        for pid in leaders { kill(-pid, SIGTERM) }
        for pid in doomed { kill(pid, SIGTERM) }
        usleep(500_000)
        // Anything forked during the grace period is a child of a survivor — catch it too.
        for pid in Array(doomed) { doomed.formUnion(descendantPIDs(of: pid)) }
        doomed.remove(me)
        for pid in leaders { kill(-pid, SIGKILL) }
        for pid in doomed { kill(pid, SIGKILL) }
    }

    /// Find orphaned processes (PPID == 1) whose working directory sits under `root`.
    /// These survive across OpenPort restarts and are invisible to port-based cleanup.
    static func findOrphans(under root: String) -> [Int32] {
        let normalizedRoot = root.hasSuffix("/") ? root : root + "/"
        // Step 1: every process's cwd via lsof (one call, scans all PIDs).
        let lsofOut = runCommand("/usr/sbin/lsof", ["-d", "cwd", "-Fpn"], timeout: 10)
        var inRoot: [Int32] = []
        var currentPid: Int32 = 0
        for line in lsofOut.components(separatedBy: "\n") {
            if line.hasPrefix("p"), let pid = Int32(line.dropFirst()) {
                currentPid = pid
            } else if line.hasPrefix("n"), currentPid != 0 {
                let dir = String(line.dropFirst())
                if dir == root || dir.hasPrefix(normalizedRoot) {
                    inRoot.append(currentPid)
                }
            }
        }
        guard !inRoot.isEmpty else { return [] }
        // Step 2: filter to those reparented to launchd (PPID=1).
        let pidList = inRoot.map(String.init).joined(separator: ",")
        let psOut = runCommand("/bin/ps", ["-p", pidList, "-o", "pid=,ppid="])
        var orphans: [Int32] = []
        let me = getpid()
        for raw in psOut.components(separatedBy: "\n") {
            let parts = raw.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 2,
                  let pid = Int32(parts[0]),
                  let ppid = Int32(parts[1]) else { continue }
            if ppid == 1, pid != me { orphans.append(pid) }
        }
        return orphans
    }

    /// Run a tool and return its stdout, never blocking longer than `timeout` (+1s grace).
    ///
    /// The pipe is drained WHILE the tool runs. Waiting for exit first deadlocked any command
    /// whose output outgrew the 64 KB pipe buffer — `lsof -d cwd` across every process always
    /// did, so the orphan sweep hit its timeout every launch and only ever saw a truncated
    /// list. A tool that outlives the timeout gets SIGKILL, not SIGTERM: an lsof wedged on a
    /// hung network mount ignores SIGTERM, and that used to stall refresh() — and with it all
    /// status polling — forever.
    private static func runCommand(_ path: String, _ args: [String], timeout: TimeInterval = 4) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        // A spawn failure (process table full — the load-600 case) must return empty, not
        // fall through to terminate() on a task that never launched, which throws an
        // Objective-C exception and takes OpenPort down with every child orphaned.
        do { try p.run() } catch { return "" }

        let output = OutputBox()
        let done = DispatchSemaphore(value: 0)
        let reader = pipe.fileHandleForReading
        DispatchQueue.global(qos: .utility).async {
            output.data = reader.readDataToEndOfFile()
            done.signal()
        }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            kill(p.processIdentifier, SIGKILL)
            _ = done.wait(timeout: .now() + 1)
        }
        return String(decoding: output.data, as: UTF8.self)
    }
}

/// Hands bytes from the reader thread back to the caller. The semaphore orders the write
/// before the read; this only exists to say so to the compiler.
private final class OutputBox: @unchecked Sendable {
    var data = Data()
}

struct DetectedServer: Sendable {
    let pid: Int32
    let port: Int
    let directory: String
    let command: String
}
