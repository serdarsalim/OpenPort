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
            // If the browser tab was still owed, the retry owes it; if this run already opened
            // one, the retry must not open a second.
            let owedBrowser = self.pendingBrowserOpen.remove(name) != nil
            let crashLog = self.processManager.crashLog(for: name)

            // A process that dies moments after Play is usually a transient — a post-reboot
            // load storm, a port not yet released by a dying predecessor — not a broken
            // project. Sweep the ports and retry once; a second death is real and shows as
            // crashed with the log. Only the user resets the budget (Stop/Play): resetting it
            // on .running let an app that boots then dies — an OOM on first compile — loop
            // forever, opening a browser tab every cycle and never showing "crashed".
            if let app = self.apps.first(where: { $0.name == name }),
               let started = app.startedAt, Date().timeIntervalSince(started) < 60,
               !self.autoRetried.contains(name) {
                self.autoRetried.insert(name)
                self.update(name) {
                    $0.isRunning = false
                    $0.portStatus = .starting
                    $0.backendRunning = false
                    $0.crashLog = crashLog
                }
                self.refreshLauncher()
                let ports = [app.detectedPort ?? app.port]
                Task { [weak self] in
                    // The crashed leader's children may outlive it and still hold the ports;
                    // retrying into EADDRINUSE would just burn the one retry for nothing.
                    await Task.detached(priority: .userInitiated) {
                        for port in ports { SystemClient.killPort(port) }
                        for _ in 0..<10 {
                            if !ports.contains(where: { SystemClient.isPortListening($0) }) { break }
                            try? await Task.sleep(nanoseconds: 500_000_000)
                        }
                    }.value
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    guard let self, self.autoRetried.contains(name),
                          let fresh = self.apps.first(where: { $0.name == name }),
                          !fresh.isRunning
                    else { return }
                    self.start(app: fresh, isRetry: true, openBrowser: owedBrowser)
                }
                return
            }

            self.autoRetried.remove(name)
            self.update(name) { app in
                app.isRunning = false
                app.portStatus = .crashed
                app.backendRunning = false
                app.crashLog = crashLog
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

    /// Apps that already used their one automatic restart after an early crash. Membership
    /// means "the next death is final" — cleared when the app reaches .running or the user
    /// intervenes, so every fresh attempt gets one retry of its own.
    private var autoRetried: Set<String> = []

    /// Starts accepted but not yet spawned: waiting on the port gate in start(), or on the
    /// teardown in a restart. Membership is the "go" token — Stop withdraws it.
    private var pendingStarts: Set<String> = []

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

        // The scan reads every package.json / openport.json / .env under the portfolio, and the
        // Node lookup lists nvm + Homebrew — file IO that has no business on the main thread
        // every 12 seconds.
        let (scanned, nodeNotes) = await Task.detached(priority: .utility) { () -> ([AppScanner.ScannedApp], [String: String]) in
            let scanned = AppScanner(portfolioRoot: root).scanWithPorts()
            var notes: [String: String] = [:]
            for item in scanned {
                notes[item.name] = NodeResolver.resolve(
                    directory: root.appendingPathComponent(item.folder),
                    convexCompat: item.backendKind == .convex
                )?.note
            }
            return (scanned, notes)
        }.value
        let appNames = scanned.map(\.name)
        let scannedByName = Dictionary(scanned.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        let scriptPorts = scannedByName.compactMapValues(\.scriptPort)
        let declaredPorts = scannedByName.compactMapValues(\.declaredPort)
        let ports = portStore.assign(to: appNames, scriptPorts: scriptPorts, declaredPorts: declaredPorts)
        let goAliases = goLinkStore.load()

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

        // Read process state AFTER the lsof wait, not before: a Play, Stop or crash that lands
        // during those 0.1–4s used to be overwritten by a snapshot taken before it happened
        // (a crashed row back to "running", a fresh Play flipped to stopped for 12s). A start
        // still waiting on its port gate counts as ours — it's about to be.
        let runningNames = Set(appNames.filter { processManager.isRunning(name: $0) || pendingStarts.contains($0) })

        // Rebuilding the array must not amnesia away state that only lives in it: a crash
        // (status + log) and the start timestamp would otherwise vanish on the next quiet
        // poll refresh, 12 seconds after the user needed to see them.
        let previous = Dictionary(apps.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })

        // Group detected listeners by the project folder they run in — the folder itself or
        // anywhere below it (a monorepo's apps/web, a `cd web && vite`). One folder may have
        // many ports. Listeners outside every project fall through to the orphan list.
        let knownFolders = Set(scanned.map(\.folder))
        let rootPrefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        var detectedByFolder: [String: [DetectedServer]] = [:]
        var outsideProjects: [DetectedServer] = []
        for entry in detected {
            if entry.directory.hasPrefix(rootPrefix),
               let folder = entry.directory.dropFirst(rootPrefix.count).split(separator: "/").first.map(String.init),
               knownFolders.contains(folder) {
                detectedByFolder[folder, default: []].append(entry)
            } else {
                outsideProjects.append(entry)
            }
        }

        // Hand each folder's listeners to its rows. A folder with one row keeps the old rule:
        // everything listening in it belongs to that row. A folder with several rows (one per
        // openport.json target) splits them: a listener on a row's declared port is that
        // row's; the rest (nudge's local Convex backend on 3210, its dashboard on 6790) go to
        // the first sibling that is up. If no sibling is up they're leftovers from a dead run
        // and surface in the orphan list, where they can be killed.
        var rowsByFolder: [String: [String]] = [:]
        for item in scanned { rowsByFolder[item.folder, default: []].append(item.name) }
        var listenersByRow: [String: [DetectedServer]] = [:]
        var unclaimed: [DetectedServer] = []
        for (folder, rows) in rowsByFolder {
            let listeners = detectedByFolder[folder] ?? []
            guard rows.count > 1 else {
                if let only = rows.first { listenersByRow[only] = listeners }
                continue
            }
            var leftovers: [DetectedServer] = []
            for listener in listeners {
                if let owner = rows.first(where: { declaredPorts[$0] == listener.port }) {
                    listenersByRow[owner, default: []].append(listener)
                } else {
                    leftovers.append(listener)
                }
            }
            guard !leftovers.isEmpty else { continue }
            let active = rows.first { runningNames.contains($0) || listenersByRow[$0]?.isEmpty == false }
            if let active { listenersByRow[active, default: []].append(contentsOf: leftovers) }
            else { unclaimed.append(contentsOf: leftovers) }
        }

        let firstRowOfFolder = Set(rowsByFolder.values.compactMap(\.first))

        apps = appNames.map { name in
            let scannedApp = scannedByName[name]
            let folder = scannedApp?.folder ?? name
            let assignedPort = ports[name] ?? 3000
            let weStartedIt = runningNames.contains(name)
            let assignedPortListening = portListening[name] ?? false
            let listenersForApp = listenersByRow[name] ?? []
            // The first instance of a multi-target project inherits the folder's alias, so
            // go/nudge keeps landing where it always did.
            let inheritsFolderAlias = folder != name && firstRowOfFolder.contains(name)
            let goAlias = goAliases[name]
                ?? (inheritsFolderAlias ? goAliases[folder] : nil)
                ?? GoLinkStore.defaultAlias(for: inheritsFolderAlias ? folder : name)

            // Pick a primary listener. A declared port is the only one a row may claim —
            // adopting "the lowest port in this folder" is how nudge's row once grabbed its
            // native sibling's 3013 while hubspot was still booting on 3012, then opened the
            // browser on the wrong stack. Sniffed projects keep the adoption fallback: a Vite
            // that ignored PORT and bound 5173 is still this row's server.
            let primary: DetectedServer?
            if let declared = declaredPorts[name] {
                primary = listenersForApp.first { $0.port == declared }
            } else {
                primary = listenersForApp.first(where: { $0.port == assignedPort })
                    ?? listenersForApp.min(by: { $0.port < $1.port })
            }

            let extras: [DetectedPort] = listenersForApp
                .filter { $0.port != primary?.port || $0.pid != primary?.pid }
                .map { DetectedPort(pid: $0.pid, port: $0.port, command: $0.command) }
                .sorted { $0.port < $1.port }

            let status: PortStatus
            let detectedPort: Int?
            let externalPID: Int32?

            if pendingStarts.contains(name) {
                // Still waiting for the old listener to let go of the port (Restart, or Play
                // right after Stop). Whatever answers on it now is the dying predecessor.
                status = .starting; detectedPort = nil; externalPID = nil
            } else if weStartedIt && assignedPortListening {
                status = .running; detectedPort = nil; externalPID = nil
            } else if weStartedIt {
                // Our process is alive but the assigned port isn't bound. Either it's still
                // booting (Convex + Next take ~20s cold) or it bound a different port (Vite
                // ignores PORT env). Adopt the primary listener; otherwise it's starting — a
                // crash is only ever declared by the termination handler.
                if let server = primary {
                    status = .running
                    detectedPort = server.port == assignedPort ? nil : server.port
                    externalPID = nil
                } else {
                    status = .starting; detectedPort = nil; externalPID = nil
                }
            } else if let server = primary {
                status = .detached
                detectedPort = server.port == assignedPort ? nil : server.port
                externalPID = server.pid
            } else if assignedPortListening {
                status = .external; detectedPort = nil; externalPID = nil
            } else if previous[name]?.portStatus == .crashed {
                // The process died and nothing else took the port — the crash (and its log)
                // stays on the row until the user restarts or stops it.
                status = .crashed; detectedPort = nil; externalPID = nil
            } else if previous[name]?.portStatus == .starting, autoRetried.contains(name) {
                // Between an early crash and its automatic retry there's a brief window with
                // no process — the row stays "starting", not "free", through it.
                status = .starting; detectedPort = nil; externalPID = nil
            } else {
                status = .free; detectedPort = nil; externalPID = nil
            }

            return DevApp(
                name: name,
                folder: folder,
                instance: scannedApp?.instance,
                port: assignedPort,
                isRunning: weStartedIt,
                portStatus: status,
                detectedPort: detectedPort,
                externalPID: externalPID,
                goAlias: goAlias,
                devScript: scannedApp?.devScript,
                devScriptName: scannedApp?.devScriptName,
                sniffScript: scannedApp?.sniffScript,
                backendKind: scannedApp?.backendKind,
                backendBundled: scannedApp?.backendBundled ?? false,
                backendNeedsLocal: scannedApp?.backendNeedsLocal ?? false,
                backendCommand: scannedApp?.backendCommand,
                backendRunning: processManager.isBackendRunning(name: name),
                nodeNote: nodeNotes[name],
                crashLog: status == .crashed ? previous[name]?.crashLog : nil,
                startedAt: weStartedIt ? previous[name]?.startedAt : nil,
                extraPorts: extras,
                runTarget: scannedApp?.runTarget,
                declaredFramework: scannedApp?.framework,
                declaredCaches: scannedApp?.cacheDirs ?? []
            )
        }

        // Anything left over — listeners whose cwd isn't a known app folder, plus a
        // multi-target folder's listeners that no running instance owns. System daemons,
        // installed Mac apps, and OpenPort itself are filtered out: killing those breaks
        // Continuity, Tailscale, ssh tunnels, etc.
        orphans = (outsideProjects + unclaimed)
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

    func start(app: DevApp, isRetry: Bool = false, openBrowser: Bool = true) {
        guard portfolioRoot != nil else { return }
        if !isRetry { autoRetried.remove(app.name) }
        guard !processManager.isRunning(name: app.name) else { return }

        update(app.name) {
            // .starting, not .running — Convex + Next stacks take ~20s to bind their port,
            // and claiming "running" for a port nobody serves is how the globe button opens
            // a dead tab. The status poll flips it to .running the moment a port answers.
            $0.isRunning = true
            $0.portStatus = .starting
            $0.startedAt = Date()
            $0.backendRunning = app.needsSidecar
        }
        if openBrowser { pendingBrowserOpen.insert(app.name) }
        pendingStarts.insert(app.name)
        refreshProxyRoutes()
        refreshLauncher()

        // Run right after Stop races the dying listener: Stop's SIGKILL fallback fires
        // 2s after SIGTERM, and Next answers a busy port by drifting to the next free
        // one — which we then poll forever while the row says "starting". So the actual
        // spawn waits until the app's ports are genuinely free, sweeping any half-dead
        // holder first — the same discipline restart() has always had. The common case
        // (ports already free) costs one connect() round before spawning.
        let ports = [app.port]
        Task {
            let busy = await Task.detached(priority: .userInitiated) {
                ports.contains { SystemClient.isPortListening($0) }
            }.value
            if busy {
                await Task.detached(priority: .userInitiated) {
                    for port in ports { SystemClient.killPort(port) }
                    for _ in 0..<10 {
                        if !ports.contains(where: { SystemClient.isPortListening($0) }) { break }
                        try? await Task.sleep(nanoseconds: 500_000_000)
                    }
                }.value
            }
            // The user may have pressed Stop while we waited (which withdraws the pending
            // start) — spawning anyway would leave a running tree behind a stopped row.
            guard pendingStarts.remove(app.name) != nil,
                  let fresh = apps.first(where: { $0.name == app.name }),
                  !processManager.isRunning(name: fresh.name) else { return }
            launchNow(app: fresh)
        }
    }

    /// The actual spawn, after start()'s port gate. Reads the app row fresh so a
    /// config change during the wait isn't lost.
    private func launchNow(app: DevApp) {
        guard let root = portfolioRoot else { return }
        processManager.start(
            name: app.name,
            port: app.port,
            in: root.appendingPathComponent(app.folder),
            devScript: app.devScript,
            devScriptName: app.devScriptName,
            sniffScript: app.sniffScript,
            primaryCommand: app.runTarget?.command,
            backendCommand: app.needsSidecar ? app.backendCommand : nil,
            convexCompat: app.backendKind == .convex,
            bindHost: launcherEnabled,
            declaredFramework: app.declaredFramework
        )
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
        let dir = root.appendingPathComponent(app.folder)
        let framework = ProcessManager.detectFramework(devScript: app.sniffScript ?? app.devScript, declared: app.declaredFramework)
        let extraCaches = app.declaredCaches
        let port = app.detectedPort ?? app.port
        let extraPids = app.extraPorts.map(\.pid)
        let externalPID = app.externalPID

        pendingBrowserOpen.remove(app.name)
        if app.isRunning { processManager.stop(name: app.name) }
        // Pending from the first moment: the row reads "starting" with a Stop button through
        // the teardown instead of a Play button that races the relaunch, and a Stop (or Stop
        // All, or Archive) in that window cancels the relaunch instead of being undone by it.
        pendingStarts.insert(app.name)
        update(app.name) {
            $0.isRunning = true; $0.portStatus = .starting; $0.startedAt = Date(); $0.detectedPort = nil
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
                if wipeCaches {
                    ProcessManager.clearCaches(in: dir, framework: framework, extra: extraCaches)
                }
                for _ in 0..<20 {
                    if !SystemClient.isPortListening(port) { break }
                    try? await Task.sleep(nanoseconds: 500_000_000)
                }
            }.value
            guard pendingStarts.contains(app.name) else { return }
            start(app: app)
        }
    }

    /// The server ran in one of our terminal tabs and just got Ctrl-C. Give its launcher a few
    /// seconds to tear its stack down the way it was written to, then stop whatever still
    /// holds the port — a job that ignores SIGINT doesn't get to keep it.
    func stopAfterInterrupt(app: DevApp) {
        pendingBrowserOpen.remove(app.name)
        Task {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            let port = app.detectedPort ?? app.port
            let stillUp = await Task.detached { SystemClient.isPortListening(port) }.value
            if stillUp, let fresh = apps.first(where: { $0.name == app.name }), fresh.portStatus == .detached {
                stop(app: fresh)
            } else {
                await refresh(quiet: true)
            }
        }
    }

    /// What "Run in Terminal Tab" types: the declared command verbatim, otherwise the dev
    /// script with this row's port. Readable on purpose — it's going into the user's shell.
    func terminalCommand(for app: DevApp) -> String {
        if let target = app.runTarget { return target.command }
        let script = app.devScriptName ?? "dev"
        let framework = ProcessManager.detectFramework(devScript: app.sniffScript ?? app.devScript,
                                                       declared: app.declaredFramework)
        // Vite ignores PORT; it takes the flag, unless a wrapper (`convex dev --start`) would
        // receive it instead — then PORT is the best we can do and the scan adopts its port.
        if framework == .vite, app.devScript?.contains("--start") != true {
            return "npm run \(script) -- --port \(app.port) --strictPort"
        }
        return "PORT=\(app.port) npm run \(script)"
    }

    /// Look up an app by name and start it. Used by the LAN launcher's Run button.
    func startByName(_ name: String) {
        guard let app = activeApps.first(where: { $0.name == name }), app.portStatus != .external else { return }
        start(app: app)
    }

    /// Look up an app by name and stop it. Used by the LAN launcher's Stop button.
    func stopByName(_ name: String) {
        guard let app = apps.first(where: { $0.name == name }) else { return }
        stop(app: app)
    }

    func stop(app: DevApp) {
        pendingBrowserOpen.remove(app.name)
        pendingStarts.remove(app.name)
        autoRetried.remove(app.name)
        if app.isRunning {
            processManager.stop(name: app.name)
        } else if let pid = app.externalPID {
            SystemClient.killTree(pid: pid)
        }
        let port = app.detectedPort ?? app.port
        let extraPids = app.extraPorts.map(\.pid)
        update(app.name) { $0.isRunning = false; $0.portStatus = .free; $0.detectedPort = nil; $0.externalPID = nil; $0.backendRunning = false; $0.crashLog = nil; $0.extraPorts = [] }
        refreshProxyRoutes()
        refreshLauncher()
        Task.detached {
            for pid in extraPids { SystemClient.killTree(pid: pid) }
            SystemClient.killPort(port)
        }
    }

    func stopAll() {
        pendingBrowserOpen.removeAll()
        pendingStarts.removeAll()
        autoRetried.removeAll()
        processManager.stopAll()

        // Scoped to rows that are actually up. Sweeping every row's assigned port used to kill
        // whatever unrelated process sat on a stopped or .external row's port (Docker, an ssh
        // tunnel) — orphans are deliberately untouched too.
        let live = apps.filter { $0.isRunning || $0.portStatus == .detached }
        let portsToKill = live.map { $0.detectedPort ?? $0.port }
        let externalPIDs = live.compactMap { $0.externalPID }
        let extraPIDs = live.flatMap { $0.extraPorts.map(\.pid) }

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
    func nukeAllSync(alsoKilling extraTrees: [Int32] = []) {
        processManager.nukeAllSync(alsoKilling: extraTrees)
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
        SystemClient.openTerminal(at: root.appendingPathComponent(app.folder))
    }

    func openEditor(for app: DevApp) {
        guard let root = portfolioRoot else { return }
        SystemClient.openVSCode(at: root.appendingPathComponent(app.folder))
    }

    func openFinder(for app: DevApp) {
        guard let root = portfolioRoot else { return }
        SystemClient.openFinder(at: root.appendingPathComponent(app.folder))
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
