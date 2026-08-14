import Foundation
import SwiftUI
import AppKit

@MainActor
final class AppModel: ObservableObject {
    @Published var apps: [DevApp] = []
    @Published var orphans: [OrphanPort] = []
    @Published var portfolioRoot: URL?
    @Published var isLoading = false

    private let processManager = ProcessManager()
    private let portStore = PortStore()
    private let goLinkStore = GoLinkStore()
    private let proxyServer = ProxyServer()
    private let launcherServer = LauncherServer()
    private let defaults = UserDefaults.standard

    init() {
        if let path = defaults.string(forKey: "portfolioRoot") {
            portfolioRoot = URL(fileURLWithPath: path)
        }
        archivedNames = Set(defaults.stringArray(forKey: "archivedApps") ?? [])
        processManager.onTerminated = { [weak self] name in
            guard let self else { return }
            self.pendingBrowserOpen.remove(name)
            self.update(name) { app in
                app.isRunning = false
                app.portStatus = .crashed
                app.backendRunning = false
                app.crashLog = self.processManager.crashLog(for: name)
            }
            self.refreshLauncher()
        }
        // The launcher's Run/Stop taps arrive on the network queue; hop to the main actor.
        launcherServer.onStart = { [weak self] name in
            Task { @MainActor in self?.startByName(name) }
        }
        launcherServer.onStop = { [weak self] name in
            Task { @MainActor in self?.stopByName(name) }
        }
        if defaults.bool(forKey: "goLinksEnabled") {
            proxyServer.start()
        }
        if defaults.bool(forKey: "launcherEnabled") {
            launcherServer.start()
        }
        startPolling()
    }

    deinit {
        pollTask?.cancel()
    }

    // MARK: - Archive

    /// Projects hidden from the dashboard, menu bar, go/ links, and LAN launcher. The scan
    /// still sees them (so unarchiving is instant and ports stay reserved) — they're folded
    /// into a collapsed section instead of cluttering the list.
    @Published private(set) var archivedNames: Set<String> = []

    var activeApps: [DevApp] { apps.filter { !archivedNames.contains($0.name) } }
    var archivedApps: [DevApp] { apps.filter { archivedNames.contains($0.name) } }

    func archive(app: DevApp) {
        // Archiving means "I don't use this" — a running server contradicts that, and a
        // hidden row must never own a live process.
        if app.isRunning || app.portStatus == .detached { stop(app: app) }
        archivedNames.insert(app.name)
        defaults.set(Array(archivedNames).sorted(), forKey: "archivedApps")
        refreshProxyRoutes()
        refreshLauncher()
    }

    func unarchive(_ name: String) {
        archivedNames.remove(name)
        defaults.set(Array(archivedNames).sorted(), forKey: "archivedApps")
        refreshProxyRoutes()
        refreshLauncher()
    }

    // MARK: - Status polling

    private var pollTask: Task<Void, Never>?
    private var pollTicks = 0

    /// Apps started via Play whose browser tab we still owe the user. Opening on click would
    /// show a dead page for the ~20s a Convex + Next stack needs; we open when the port answers.
    private var pendingBrowserOpen: Set<String> = []

    var openBrowserOnReady: Bool {
        get { defaults.object(forKey: "openBrowserOnReady") == nil ? true : defaults.bool(forKey: "openBrowserOnReady") }
        set { defaults.set(newValue, forKey: "openBrowserOnReady") }
    }

    /// Flip a row to .running and, if this run still owes a browser tab, open it now.
    private func markRunning(_ name: String, port: Int) {
        update(name) { $0.portStatus = .running }
        if pendingBrowserOpen.remove(name) != nil, openBrowserOnReady {
            SystemClient.openBrowser(port: port)
        }
        refreshLauncher()
    }

    /// The dashboard is only trustworthy if it tracks reality without being asked. Every 3s
    /// we probe the ports of apps we started (a connect() each — negligible); every 4th tick
    /// we run a full quiet refresh, which adopts mismatched ports via lsof (a Vite that booted
    /// on 5173 while we assigned 3015) and picks up servers started or stopped in a terminal.
    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                await self?.pollTick()
            }
        }
    }

    private func pollTick() async {
        guard !apps.isEmpty else { return }
        pollTicks += 1

        for app in apps where app.isRunning {
            let port = app.detectedPort ?? app.port
            let listening = await Task.detached { SystemClient.isPortListening(port) }.value
            // The process may have exited while we probed — .crashed belongs to the
            // termination handler alone, so only adjust status while it's still alive.
            guard processManager.isRunning(name: app.name) else { continue }
            if listening, app.portStatus != .running {
                markRunning(app.name, port: port)
            } else if !listening, app.portStatus == .running {
                // Port dropped but the process lives — a dev server mid-restart, not a crash.
                update(app.name) { $0.portStatus = .starting; $0.detectedPort = nil }
            }
        }

        if pollTicks % 4 == 0 {
            await refresh(quiet: true)
        }
    }

    func setPortfolioRoot(_ url: URL) {
        portfolioRoot = url
        defaults.set(url.path, forKey: "portfolioRoot")
        Task { await refresh() }
    }

    private var refreshInFlight = false

    func refresh(quiet: Bool = false) async {
        guard let root = portfolioRoot, !refreshInFlight else { return }
        refreshInFlight = true
        if !quiet { isLoading = true }
        defer {
            refreshInFlight = false
            if !quiet { isLoading = false }
        }

        let scanner = AppScanner(portfolioRoot: root)
        let scanned = scanner.scanWithPorts()
        let appNames = scanned.map(\.name)
        let scriptPorts = Dictionary(uniqueKeysWithValues: scanned.compactMap { item -> (String, Int)? in
            guard let p = item.scriptPort else { return nil }
            return (item.name, p)
        })
        let devScripts = Dictionary(uniqueKeysWithValues: scanned.compactMap { item -> (String, String)? in
            guard let s = item.devScript else { return nil }
            return (item.name, s)
        })
        let devScriptNames = Dictionary(uniqueKeysWithValues: scanned.compactMap { item -> (String, String)? in
            guard let n = item.devScriptName else { return nil }
            return (item.name, n)
        })
        let sniffScripts = Dictionary(uniqueKeysWithValues: scanned.compactMap { item -> (String, String)? in
            guard let s = item.sniffScript else { return nil }
            return (item.name, s)
        })
        let scannedByName = Dictionary(uniqueKeysWithValues: scanned.map { ($0.name, $0) })
        let declaredPorts = Dictionary(uniqueKeysWithValues: scanned.compactMap { item -> (String, Int)? in
            guard let p = item.declaredPort else { return nil }
            return (item.name, p)
        })
        let ports = portStore.assign(to: appNames, scriptPorts: scriptPorts, declaredPorts: declaredPorts)
        let goAliases = goLinkStore.load()
        let runningNames = Set(appNames.filter { processManager.isRunning(name: $0) })

        async let portTask = withTaskGroup(of: (String, Bool).self) { group in
            for name in appNames {
                let port = ports[name] ?? 3000
                group.addTask { (name, SystemClient.isPortListening(port)) }
            }
            var r: [String: Bool] = [:]
            for await (name, listening) in group { r[name] = listening }
            return r
        }

        async let detectTask = Task.detached { SystemClient.detectRunningServers() }.value

        let (portListening, detected) = await (portTask, detectTask)

        // Rebuilding the array must not amnesia away state that only lives in it: a crash
        // (status + log) and the start timestamp would otherwise vanish on the next quiet
        // poll refresh, 12 seconds after the user needed to see them.
        let previous = Dictionary(uniqueKeysWithValues: apps.map { ($0.name, $0) })

        // Group all detected listeners by their cwd. One cwd may have many ports.
        var detectedByDir: [String: [DetectedServer]] = [:]
        for entry in detected {
            detectedByDir[entry.directory, default: []].append(entry)
        }

        let appDirSet = Set(appNames.map { root.appendingPathComponent($0).path })

        apps = appNames.map { name in
            let appDir = root.appendingPathComponent(name).path
            let assignedPort = ports[name] ?? 3000
            let weStartedIt = runningNames.contains(name)
            let assignedPortListening = portListening[name] ?? false
            let listenersForApp = detectedByDir[appDir] ?? []
            let goAlias = goAliases[name] ?? GoLinkStore.defaultAlias(for: name)

            // Pick a primary listener: prefer the one matching the assigned port,
            // otherwise the lowest-numbered port.
            let primary: DetectedServer? = listenersForApp.first(where: { $0.port == assignedPort })
                ?? listenersForApp.min(by: { $0.port < $1.port })

            let extras: [DetectedPort] = listenersForApp
                .filter { $0.port != primary?.port || $0.pid != primary?.pid }
                .map { DetectedPort(pid: $0.pid, port: $0.port, command: $0.command) }
                .sorted { $0.port < $1.port }

            let status: PortStatus
            let detectedPort: Int?
            let externalPID: Int32?

            if weStartedIt && assignedPortListening {
                status = .running; detectedPort = nil; externalPID = nil
            } else if weStartedIt {
                // Our process is alive but the assigned port isn't bound. Either it's still
                // booting (Convex + Next take ~20s cold) or it bound a different port (Vite
                // ignores PORT env). Adopt any listener in this app's directory; otherwise
                // it's starting — a crash is only ever declared by the termination handler.
                if let server = primary {
                    status = .running; detectedPort = server.port; externalPID = nil
                } else {
                    status = .starting; detectedPort = nil; externalPID = nil
                }
            } else if let server = primary {
                status = .detached; detectedPort = server.port; externalPID = server.pid
            } else if assignedPortListening {
                status = .external; detectedPort = nil; externalPID = nil
            } else if previous[name]?.portStatus == .crashed {
                // The process died and nothing else took the port — the crash (and its log)
                // stays on the row until the user restarts or stops it.
                status = .crashed; detectedPort = nil; externalPID = nil
            } else {
                status = .free; detectedPort = nil; externalPID = nil
            }

            let scannedApp = scannedByName[name]
            let nodeNote: String? = NodeResolver.resolve(
                directory: root.appendingPathComponent(name),
                convexCompat: scannedApp?.backendKind == .convex
            )?.note

            return DevApp(
                name: name,
                port: assignedPort,
                isRunning: weStartedIt,
                portStatus: status,
                detectedPort: detectedPort,
                externalPID: externalPID,
                goAlias: goAlias,
                devScript: devScripts[name],
                devScriptName: devScriptNames[name],
                sniffScript: sniffScripts[name],
                backendKind: scannedApp?.backendKind,
                backendBundled: scannedApp?.backendBundled ?? false,
                backendNeedsLocal: scannedApp?.backendNeedsLocal ?? false,
                backendCommand: scannedApp?.backendCommand,
                backendRunning: processManager.isBackendRunning(name: name),
                nodeNote: nodeNote,
                crashLog: status == .crashed ? previous[name]?.crashLog : nil,
                startedAt: weStartedIt ? previous[name]?.startedAt : nil,
                extraPorts: extras,
                runTargets: scannedApp?.runTargets ?? [],
                declaredFramework: scannedApp?.framework,
                declaredCaches: scannedApp?.cacheDirs ?? []
            )
        }

        // Anything left over — listeners whose cwd isn't a known app folder.
        // System daemons, installed Mac apps, and OpenPort itself are filtered
        // out: killing those breaks Continuity, Tailscale, ssh tunnels, etc.
        orphans = detected
            .filter { !appDirSet.contains($0.directory) }
            .filter { !Self.isSystemOrInstalledApp($0) }
            .map { OrphanPort(pid: $0.pid, port: $0.port, directory: $0.directory, command: $0.command) }
            .sorted { $0.port < $1.port }

        refreshProxyRoutes()
        refreshLauncher()

        // A quiet refresh may be the first to see a started app answering (possibly on an
        // adopted port a full lsof sweep just discovered) — settle the owed browser tab here too.
        for app in apps where app.isRunning && app.portStatus == .running && pendingBrowserOpen.contains(app.name) {
            pendingBrowserOpen.remove(app.name)
            if openBrowserOnReady { SystemClient.openBrowser(port: app.detectedPort ?? app.port) }
        }
    }

    /// Hide listeners that aren't user dev servers — system daemons, Mac apps,
    /// ssh tunnels, OpenPort itself.
    private static func isSystemOrInstalledApp(_ entry: DetectedServer) -> Bool {
        let cmd = entry.command
        let dir = entry.directory

        let blockedCommandPrefixes = [
            "/System/", "/usr/", "/Library/", "/Applications/",
            "/sbin/", "/bin/"
        ]
        if blockedCommandPrefixes.contains(where: { cmd.hasPrefix($0) }) { return true }

        if cmd.contains("LocalhostApp") || cmd.contains("OpenPort.app") { return true }

        if dir.isEmpty || dir == "/" { return true }

        let blockedDirPrefixes = [
            "/System/", "/Library/", "/private/var/", "/Applications/"
        ]
        if blockedDirPrefixes.contains(where: { dir.hasPrefix($0) }) { return true }

        return false
    }

    /// Kill an orphan listener by PID. Scoped narrowly — does NOT participate
    /// in stopAll(), since orphans may be unrelated apps the user cares about.
    func stopOrphan(_ orphan: OrphanPort) {
        SystemClient.killTree(pid: orphan.pid)
        orphans.removeAll { $0.id == orphan.id }
    }

    func liveLog(for app: DevApp) -> String? {
        processManager.liveLog(for: app.name)
    }

    func clearLog(for app: DevApp) {
        processManager.clearLog(for: app.name)
    }

    func start(app: DevApp) {
        guard let root = portfolioRoot else { return }
        processManager.start(
            name: app.name,
            port: app.port,
            in: root.appendingPathComponent(app.name),
            devScript: app.devScript,
            devScriptName: app.devScriptName,
            sniffScript: app.sniffScript,
            primaryCommand: app.primaryTarget?.command,
            sidecars: app.sidecarTargets,
            backendCommand: app.needsSidecar ? app.backendCommand : nil,
            convexCompat: app.backendKind == .convex,
            bindHost: launcherEnabled,
            declaredFramework: app.declaredFramework
        )
        update(app.name) {
            // .starting, not .running — Convex + Next stacks take ~20s to bind their port,
            // and claiming "running" for a port nobody serves is how the globe button opens
            // a dead tab. The status poll flips it to .running the moment a port answers.
            $0.isRunning = true
            $0.portStatus = .starting
            $0.startedAt = Date()
            $0.backendRunning = app.needsSidecar || !app.sidecarTargets.isEmpty
        }
        pendingBrowserOpen.insert(app.name)
        refreshProxyRoutes()
        refreshLauncher()
    }

    /// Plain restart: stop, wait for the ports to actually free, start again. Replaces the
    /// manual Stop → wait → Play dance. Works on detached (terminal-started) servers too.
    func restart(app: DevApp) {
        stopAndRelaunch(app: app, wipeCaches: false)
    }

    /// Stop, wipe the framework's build cache, then start fresh. Cures the case where a dev
    /// server wedges on compile (pegged CPU, port open but never responds) and a plain restart
    /// doesn't help because it reuses the poisoned cache. No-op cache-wise for frameworks we
    /// don't recognize, in which case it's just a restart.
    func cleanRestart(app: DevApp) {
        stopAndRelaunch(app: app, wipeCaches: true)
    }

    private func stopAndRelaunch(app: DevApp, wipeCaches: Bool) {
        guard let root = portfolioRoot else { return }
        let dir = root.appendingPathComponent(app.name)
        let framework = ProcessManager.detectFramework(devScript: app.sniffScript ?? app.devScript, declared: app.declaredFramework)
        let extraCaches = app.declaredCaches
        let port = app.detectedPort ?? app.port
        let sidecarPorts = app.sidecarTargets.compactMap(\.port)
        let extraPids = app.extraPorts.map(\.pid)
        let externalPID = app.externalPID

        pendingBrowserOpen.remove(app.name)
        if app.isRunning { processManager.stop(name: app.name) }
        update(app.name) {
            $0.isRunning = false; $0.portStatus = .free; $0.detectedPort = nil
            $0.externalPID = nil; $0.backendRunning = false; $0.crashLog = nil; $0.extraPorts = []
        }
        refreshProxyRoutes()
        refreshLauncher()

        // Tear down and (optionally) clear the cache off the main thread — a large .next can
        // take a second to delete — then start once the ports are genuinely free. killTree's
        // SIGKILL fallback fires 2s after SIGTERM, so relaunching immediately would race a
        // dying listener and strictPort would abort the fresh boot for nothing.
        Task {
            await Task.detached(priority: .userInitiated) {
                if let externalPID { SystemClient.killTree(pid: externalPID) }
                for pid in extraPids { SystemClient.killTree(pid: pid) }
                SystemClient.killPort(port)
                for sidecarPort in sidecarPorts { SystemClient.killPort(sidecarPort) }
                if wipeCaches {
                    ProcessManager.clearCaches(in: dir, framework: framework, extra: extraCaches)
                }
                for _ in 0..<20 {
                    let busy = ([port] + sidecarPorts).contains { SystemClient.isPortListening($0) }
                    if !busy { break }
                    try? await Task.sleep(nanoseconds: 500_000_000)
                }
            }.value
            start(app: app)
        }
    }

    /// Look up an app by name and start it. Used by the LAN launcher's Run button.
    func startByName(_ name: String) {
        guard let app = apps.first(where: { $0.name == name }), app.portStatus != .external else { return }
        start(app: app)
    }

    /// Look up an app by name and stop it. Used by the LAN launcher's Stop button.
    func stopByName(_ name: String) {
        guard let app = apps.first(where: { $0.name == name }) else { return }
        stop(app: app)
    }

    func stop(app: DevApp) {
        pendingBrowserOpen.remove(app.name)
        if app.isRunning {
            processManager.stop(name: app.name)
        } else if let pid = app.externalPID {
            SystemClient.killTree(pid: pid)
        }
        let port = app.detectedPort ?? app.port
        let extraPids = app.extraPorts.map(\.pid)
        // Declared sidecar ports are swept too: lsof only sees a target that was still up when
        // we last scanned, and a half-dead second stack holding 3013 blocks the next Run.
        let sidecarPorts = app.sidecarTargets.compactMap(\.port)
        update(app.name) { $0.isRunning = false; $0.portStatus = .free; $0.detectedPort = nil; $0.externalPID = nil; $0.backendRunning = false; $0.crashLog = nil; $0.extraPorts = [] }
        refreshProxyRoutes()
        refreshLauncher()
        Task.detached {
            for pid in extraPids { SystemClient.killTree(pid: pid) }
            SystemClient.killPort(port)
            for sidecarPort in sidecarPorts { SystemClient.killPort(sidecarPort) }
        }
    }

    func stopAll() {
        pendingBrowserOpen.removeAll()
        processManager.stopAll()

        // Stays scoped to listed apps — orphans are deliberately untouched.
        let portsToKill = apps.map { $0.detectedPort ?? $0.port }
        let externalPIDs = apps.compactMap { $0.externalPID }
        let extraPIDs = apps.flatMap { $0.extraPorts.map(\.pid) }

        for idx in apps.indices {
            apps[idx].isRunning = false
            apps[idx].portStatus = .free
            apps[idx].detectedPort = nil
            apps[idx].externalPID = nil
            apps[idx].backendRunning = false
            apps[idx].extraPorts = []
        }
        refreshProxyRoutes()
        refreshLauncher()

        Task.detached {
            for pid in externalPIDs { SystemClient.killTree(pid: pid) }
            for pid in extraPIDs { SystemClient.killTree(pid: pid) }
            for port in portsToKill { SystemClient.killPort(port) }
        }
    }

    /// Synchronous shutdown. Blocks ~500ms so children die before OpenPort exits, otherwise
    /// they reparent to launchd and outlive every future OpenPort launch invisibly.
    func nukeAllSync() {
        processManager.nukeAllSync()
        let pids = apps.compactMap { $0.externalPID } + apps.flatMap { $0.extraPorts.map(\.pid) }
        for pid in pids { kill(pid, SIGTERM) }
        usleep(300_000)
        for pid in pids { kill(pid, SIGKILL) }
    }

    /// Reap leftover processes from a previous (crashed/quit-without-cleanup) OpenPort session.
    /// Targets only orphans (PPID==1) whose cwd is under the portfolio root, so we can't hit
    /// random user processes.
    func reapPortfolioOrphans() {
        guard let root = portfolioRoot?.path else { return }
        Task.detached {
            let orphans = SystemClient.findOrphans(under: root)
            guard !orphans.isEmpty else { return }
            for pid in orphans { SystemClient.killTree(pid: pid) }
        }
    }

    func updatePort(for app: DevApp, port: Int) {
        var ports = portStore.load()
        ports[app.name] = port
        portStore.save(ports)
        update(app.name) { $0.port = port }
        refreshLauncher()
    }

    func updateGoAlias(for app: DevApp, alias: String) {
        let clean = alias.trimmingCharacters(in: .whitespacesAndNewlines)
        goLinkStore.setAlias(clean, for: app.name)
        update(app.name) { $0.goAlias = clean.isEmpty ? GoLinkStore.defaultAlias(for: app.name) : clean }
        refreshProxyRoutes()
    }

    func setGoLinksEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: "goLinksEnabled")
        if enabled {
            proxyServer.start()
            refreshProxyRoutes()
        } else {
            proxyServer.stop()
        }
    }

    var goLinksEnabled: Bool { defaults.bool(forKey: "goLinksEnabled") }

    // MARK: - LAN Launcher

    var launcherEnabled: Bool { defaults.bool(forKey: "launcherEnabled") }

    /// The launcher's own URL — what the footer QR encodes and Settings displays.
    var launcherURL: String { "http://\(SystemClient.lanIPAddress()):\(LauncherServer.port)" }

    func setLauncherEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: "launcherEnabled")
        if enabled {
            launcherServer.start()
            refreshLauncher()
        } else {
            launcherServer.stop()
        }
    }

    private func refreshLauncher() {
        let infos = activeApps.map { app in
            LaunchAppInfo(
                name: app.name,
                port: app.detectedPort ?? app.port,
                isExternal: app.portStatus == .external,
                backendLabel: app.hasBackend ? app.backendKind?.label : nil
            )
        }
        launcherServer.update(apps: infos, lanIP: SystemClient.lanIPAddress())
    }

    func openTerminal(for app: DevApp) {
        guard let root = portfolioRoot else { return }
        SystemClient.openTerminal(at: root.appendingPathComponent(app.name))
    }

    func openEditor(for app: DevApp) {
        guard let root = portfolioRoot else { return }
        SystemClient.openVSCode(at: root.appendingPathComponent(app.name))
    }

    func openFinder(for app: DevApp) {
        guard let root = portfolioRoot else { return }
        SystemClient.openFinder(at: root.appendingPathComponent(app.name))
    }

    private func refreshProxyRoutes() {
        guard defaults.bool(forKey: "goLinksEnabled") else { return }
        var routes: [String: Int] = [:]
        for app in activeApps {
            routes[app.goAlias] = app.detectedPort ?? app.port
        }
        proxyServer.updateRoutes(routes)
    }

    private func update(_ name: String, _ mutation: (inout DevApp) -> Void) {
        guard let idx = apps.firstIndex(where: { $0.name == name }) else { return }
        mutation(&apps[idx])
    }
}
