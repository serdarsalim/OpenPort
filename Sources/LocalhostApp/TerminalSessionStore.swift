import AppKit
import Combine
import Foundation
import SwiftTerm

/// What a terminal tab is busy with right now — the shell's foreground child and every port
/// its process tree listens on. Drives the tab title ("nudge:hubspot :3012") so a tab running
/// a server says so, and lets a dashboard row jump to the tab that serves it.
struct TerminalJob: Equatable, Sendable {
    let label: String    // "hubspot", "claude", "vite"
    let command: String  // full command line of the shell's child
    let ports: [Int]     // sorted listening ports anywhere in the job's tree

    var isServer: Bool { !ports.isEmpty }
}

@MainActor
final class TerminalSession: ObservableObject, Identifiable {
    let id = UUID()
    /// What the tab shows. Derived — set `job`, `oscTitle` or `folder` instead.
    @Published private(set) var title: String
    @Published var query: String = ""
    @Published private(set) var job: TerminalJob?
    let cwd: URL
    let terminalView: LocalProcessTerminalView
    private let delegateProxy: ProcessDelegate
    private let initialTitle: String
    /// The shell's current directory (full path), tracked so the title follows `cd` and a
    /// row's terminal button can find a tab already sitting in its project.
    private(set) var currentDirectory: String?
    private var folder: String? {
        guard let currentDirectory else { return nil }
        if currentDirectory == FileManager.default.homeDirectoryForCurrentUser.path { return "~" }
        return (currentDirectory as NSString).lastPathComponent
    }
    /// Whatever the shell itself asked for via an OSC title escape, if anything.
    private var oscTitle: String?

    init(title: String, cwd: URL, onTerminated: @escaping (UUID) -> Void) {
        self.title = title
        self.initialTitle = title
        self.cwd = cwd
        let view = LocalProcessTerminalView(frame: .zero)
        self.terminalView = view

        let proxy = ProcessDelegate()
        self.delegateProxy = proxy
        view.processDelegate = proxy

        let sessionId = id
        proxy.onTerminated = { onTerminated(sessionId) }
        proxy.onTitle = { [weak self] newTitle in
            guard let self else { return }
            let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            self.oscTitle = trimmed.isEmpty ? nil : trimmed
            self.updateTitle()
        }

        TerminalAppearance.fromDefaults().apply(to: view)

        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        var env = Terminal.getEnvironmentVariables(termName: "xterm-256color")
        env.append("PWD=\(cwd.path)")
        view.startProcess(executable: shell, args: ["-l"], environment: env, execName: nil)
        // PWD env alone doesn't chdir the shell — send a cd command on first prompt.
        let escaped = cwd.path.replacingOccurrences(of: "'", with: "'\\''")
        view.send(txt: "cd '\(escaped)' && clear\n")
    }

    var shellPID: Int32 { terminalView.process.shellPid }

    /// The pty's foreground process group: the shell's own when it sits at a prompt, the
    /// job's while something runs. Same signal Terminal.app and iTerm use — unlike "the
    /// shell's newest child", it isn't fooled by prompt helpers (gitstatusd, async workers)
    /// that the shell keeps running in the background.
    var foregroundGroup: Int32 {
        let fd = terminalView.process.childfd
        return fd >= 0 ? tcgetpgrp(fd) : -1
    }

    func apply(job: TerminalJob?, directory: String?) {
        guard job != self.job || directory != currentDirectory else { return }
        self.job = job
        currentDirectory = directory
        updateTitle()
    }

    /// The shell is at its prompt right now (checked live, not from the 2s scan), so typing
    /// into it starts a command rather than feeding a running server's stdin.
    var isAtPrompt: Bool {
        let fg = foregroundGroup
        return fg > 0 && fg == shellPID
    }

    /// Where the shell is, falling back to where the tab opened before the first scan.
    var directoryPath: String { currentDirectory ?? cwd.path }

    /// Idle: the folder (or the shell's own OSC title). Busy: "folder:job", plus the port when
    /// the job serves one — the difference between "a terminal" and "the hubspot server".
    private func updateTitle() {
        let base = folder ?? initialTitle
        let next: String
        if let job {
            let port = job.ports.first.map { " :\($0)" } ?? ""
            next = job.label == base ? "\(base)\(port)" : "\(base):\(job.label)\(port)"
        } else {
            next = oscTitle ?? base
        }
        if next != title { title = next }
    }

    /// Ctrl-C to the foreground job — the same thing the user would type. A launcher like
    /// nudge's dev scripts traps SIGINT and tears its whole stack down cleanly, which a
    /// SIGTERM aimed at the one pid holding the port does not.
    func interrupt() {
        terminalView.send(txt: "\u{03}")
    }

    /// Type a command into the shell and run it.
    func run(_ command: String) {
        terminalView.send(txt: command + "\n")
    }

    func terminate() {
        terminalView.process.terminate()
    }
}

private final class ProcessDelegate: NSObject, LocalProcessTerminalViewDelegate {
    var onTerminated: (() -> Void)?
    var onTitle: ((String) -> Void)?

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        onTitle?(title)
    }
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func processTerminated(source: TerminalView, exitCode: Int32?) {
        onTerminated?()
    }
}

@MainActor
final class TerminalSessionStore: ObservableObject {
    @Published var sessions: [TerminalSession] = [] {
        didSet { sessions.isEmpty ? stopWatchingJobs() : startWatchingJobs() }
    }
    @Published var selectedTab: TabSelection = .dashboard

    enum TabSelection: Equatable {
        case dashboard
        case session(UUID)
    }

    @discardableResult
    func openSession(title: String, cwd: URL) -> TerminalSession {
        let session = TerminalSession(title: title, cwd: cwd) { [weak self] id in
            Task { @MainActor in self?.handleProcessExit(id) }
        }
        sessions.append(session)
        selectedTab = .session(session.id)
        return session
    }

    /// Run `command` in a tab in `cwd` — a server you can watch, scroll and Ctrl-C, with a
    /// real TTY. Reuses an idle tab already in that folder; the tab names itself once the job
    /// is up.
    func run(_ command: String, title: String, cwd: URL) {
        let session = idleSession(in: cwd) ?? openSession(title: title, cwd: cwd)
        selectedTab = .session(session.id)
        session.run(command)
        Task { await refreshJobs() }
    }

    /// Focus a tab that's idle in `cwd`, or open one. The row's terminal button used to open
    /// a new tab every click, so a project ended up with three tabs all called "nudge".
    func openOrFocusSession(title: String, cwd: URL) {
        if let existing = idleSession(in: cwd) {
            selectedTab = .session(existing.id)
        } else {
            openSession(title: title, cwd: cwd)
        }
    }

    private func idleSession(in cwd: URL) -> TerminalSession? {
        let target = Self.canonical(cwd.path)
        return sessions.first { $0.isAtPrompt && Self.canonical($0.directoryPath) == target }
    }

    /// lsof reports the resolved path; the portfolio root may arrive with a symlink or a
    /// trailing slash. Compare like with like.
    private static func canonical(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }

    func openHomeSession() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let title = ProcessInfo.processInfo.environment["SHELL"]
            .map { ($0 as NSString).lastPathComponent } ?? "zsh"
        openSession(title: title, cwd: home)
    }

    func close(_ id: UUID) {
        guard let idx = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[idx].terminate()
        sessions.remove(at: idx)

        if case .session(let current) = selectedTab, current == id {
            // Pick a neighboring tab, or fall back to the dashboard.
            if !sessions.isEmpty {
                let next = sessions[min(idx, sessions.count - 1)]
                selectedTab = .session(next.id)
            } else {
                selectedTab = .dashboard
            }
        }
    }

    /// Login-shell PIDs of every open tab — the roots of whatever the user is running in them.
    var shellPIDs: [Int32] {
        sessions.map(\.shellPID).filter { $0 > 0 }
    }

    /// The tab whose job listens on `port`, if a server runs in one of our tabs.
    func session(servingPort port: Int) -> TerminalSession? {
        sessions.first { $0.job?.ports.contains(port) == true }
    }

    func select(_ id: UUID) {
        selectedTab = .session(id)
    }

    func applyAppearance() {
        let appearance = TerminalAppearance.fromDefaults()
        for session in sessions {
            appearance.apply(to: session.terminalView)
        }
    }

    private func handleProcessExit(_ id: UUID) {
        // Process died on its own (user typed `exit`, etc.). Drop the tab.
        close(id)
    }

    // MARK: - Job watching

    private var jobTask: Task<Void, Never>?

    /// Every 2s while any tab is open: one `ps` for the whole process table, one `lsof` for
    /// the cwd of each shell, one `lsof` for listeners in the tabs' trees — all off the main
    /// thread. Nothing runs when no tab is open.
    private func startWatchingJobs() {
        guard jobTask == nil else { return }
        jobTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshJobs()
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    private func stopWatchingJobs() {
        jobTask?.cancel()
        jobTask = nil
    }

    private func refreshJobs() async {
        let shells = sessions.map { JobScanner.Shell(pid: $0.shellPID, foreground: $0.foregroundGroup) }
            .filter { $0.pid > 0 }
        guard !shells.isEmpty else { return }
        let snapshot = await Task.detached(priority: .utility) {
            JobScanner.scan(shells: shells)
        }.value
        var changed = false
        for session in sessions {
            let found = snapshot[session.shellPID]
            if found?.job != session.job { changed = true }
            session.apply(job: found?.job, directory: found?.directory)
        }
        // Rows observe the store, not each session: tell them when a tab starts or stops
        // serving a port so "terminal → jump to tab" stays current.
        if changed { objectWillChange.send() }
    }
}

/// Reads what each terminal tab's shell is running. Pure process-table inspection — no
/// shell integration needed, so it works for any shell and any command.
private enum JobScanner {
    struct Shell: Sendable {
        let pid: Int32
        let foreground: Int32  // tcgetpgrp of the tab's pty
    }

    struct Result: Sendable {
        let directory: String?
        let job: TerminalJob?
    }

    static func scan(shells: [Shell]) -> [Int32: Result] {
        // 1. Whole process table once: pid → (pgid, command), plus the child map.
        var command: [Int32: String] = [:]
        var groupLeaderFallback: [Int32: Int32] = [:]  // pgid → lowest pid in it
        var children: [Int32: [Int32]] = [:]
        for line in run("/bin/ps", ["-Ao", "pid=,ppid=,pgid=,command="]).split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            guard parts.count == 4, let pid = Int32(parts[0]), let ppid = Int32(parts[1]),
                  let pgid = Int32(parts[2]) else { continue }
            command[pid] = String(parts[3])
            children[ppid, default: []].append(pid)
            groupLeaderFallback[pgid] = min(groupLeaderFallback[pgid] ?? pid, pid)
        }

        // 2. Each tab's job: the leader of the pty's foreground process group, unless that
        //    group is the shell itself (idle at a prompt). Its tree includes children that
        //    detached into their own sessions (nudge's launchers do), since ppid still links them.
        var jobRoot: [Int32: Int32] = [:]
        var tree: [Int32: Set<Int32>] = [:]
        for shell in shells {
            let fg = shell.foreground
            guard fg > 0, fg != shell.pid,
                  let root = command[fg] != nil ? fg : groupLeaderFallback[fg]
            else { continue }
            jobRoot[shell.pid] = root
            var seen: Set<Int32> = []
            var queue = [root]
            while let pid = queue.popLast() {
                guard seen.insert(pid).inserted else { continue }
                queue.append(contentsOf: children[pid] ?? [])
            }
            tree[shell.pid] = seen
        }

        // 3. Listening ports for every pid in any job tree — one lsof call.
        var portsByPid: [Int32: Set<Int>] = [:]
        let allPids = tree.values.flatMap { $0 }
        if !allPids.isEmpty {
            var current: Int32 = 0
            let out = run("/usr/sbin/lsof", ["-a", "-p", allPids.map(String.init).joined(separator: ","),
                                              "-iTCP", "-sTCP:LISTEN", "-nP", "-Fpn"])
            for line in out.split(separator: "\n") {
                if line.hasPrefix("p") { current = Int32(line.dropFirst()) ?? 0 }
                else if line.hasPrefix("n"), let port = line.split(separator: ":").last.flatMap({ Int($0) }) {
                    portsByPid[current, default: []].insert(port)
                }
            }
        }

        // 4. Each shell's cwd, so the title follows `cd`.
        var cwdByPid: [Int32: String] = [:]
        var current: Int32 = 0
        let cwdOut = run("/usr/sbin/lsof", ["-a", "-p", shells.map { String($0.pid) }.joined(separator: ","), "-d", "cwd", "-Fpn"])
        for line in cwdOut.split(separator: "\n") {
            if line.hasPrefix("p") { current = Int32(line.dropFirst()) ?? 0 }
            else if line.hasPrefix("n") { cwdByPid[current] = String(line.dropFirst()) }
        }

        var result: [Int32: Result] = [:]
        for shell in shells.map(\.pid) {
            let directory = cwdByPid[shell]
            guard let root = jobRoot[shell], let cmd = command[root] else {
                result[shell] = Result(directory: directory, job: nil)
                continue
            }
            let ports = (tree[shell] ?? []).reduce(into: Set<Int>()) { $0.formUnion(portsByPid[$1] ?? []) }
            result[shell] = Result(
                directory: directory,
                job: TerminalJob(label: CommandLabel.label(for: cmd), command: cmd, ports: ports.sorted())
            )
        }
        return result
    }

    private static func run(_ path: String, _ args: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return "" }
        // Read before waiting: a full pipe buffer would block the child forever otherwise.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}
