import SwiftUI
import CoreImage
import AppKit

struct AppRowView: View {
    let app: DevApp
    @ObservedObject var model: AppModel
    @State private var editingPort = false
    @State private var portDraft = ""
    @State private var portConflict = false
    @FocusState private var portFieldFocused: Bool
    @State private var copied = false
    @State private var showQR = false
    @State private var editingGoAlias = false
    @State private var goAliasDraft = ""
    @FocusState private var goAliasFieldFocused: Bool
    @AppStorage("goLinksEnabled") private var goLinksEnabled = false
    @AppStorage("showActionBrowser") private var showActionBrowser = true
    @AppStorage("showActionCopy") private var showActionCopy = true
    @AppStorage("showActionQR") private var showActionQR = false
    @AppStorage("showActionTerminal") private var showActionTerminal = true
    @AppStorage("showActionEditor") private var showActionEditor = true
    @AppStorage("showActionFinder") private var showActionFinder = true
    @AppStorage("showActionLogs") private var showActionLogs = true
    @AppStorage("useExternalTerminal") private var useExternalTerminal = false
    @EnvironmentObject private var terminalStore: TerminalSessionStore
    @State private var showLogs = false
    @State private var isHovered = false
    @State private var showCrashLog = false
    @State private var showPortsPopover = false

    private var takenPorts: Set<Int> {
        Set(model.apps.filter { $0.name != app.name }.map { $0.port })
    }


    var body: some View {
        HStack(spacing: 14) {
            startStopButton
            appName
            if goLinksEnabled { goLinkBadge }
            portBadge
            statusBadge
            Spacer(minLength: 24)
            actionButtons
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 10)
        .background(isHovered ? Color.primary.opacity(0.09) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .onHover { isHovered = $0 }
        .sheet(isPresented: $showLogs) {
            LogsSheet(app: app, model: model)
        }
        .contextMenu {
            if !app.isRunning && app.portStatus != .detached && app.portStatus != .external {
                Button {
                    runInTerminalTab()
                } label: {
                    Label("Run in Terminal Tab", systemImage: "terminal")
                }
                .help("Run \(model.terminalCommand(for: app)) in a new tab — live output, Ctrl-C to stop")
            }
            if let cacheLabel {
                Button {
                    model.cleanRestart(app: app)
                } label: {
                    Label("Clean Restart — clear \(cacheLabel) cache",
                          systemImage: "arrow.triangle.2.circlepath")
                }
                .help("Stop, delete the build cache, then start fresh. Use when the server is wedged and a plain restart doesn't fix it.")
            }
            Button {
                model.archive(app: app)
            } label: {
                Label("Archive", systemImage: "archivebox")
            }
            .help("Hide this project in the Archived section at the bottom of the list. Stops it first if running.")
        }
    }

    /// The framework cache this app's dev server reuses between runs (e.g. ".next"). nil when
    /// we don't recognize the framework — we hide Clean Restart rather than offer a no-op.
    private var cacheLabel: String? {
        app.declaredCaches.first ?? ProcessManager.cacheDirs(for: ProcessManager.detectFramework(
            devScript: app.sniffScript ?? app.devScript, declared: app.declaredFramework)).first
    }

    private var appName: some View {
        VStack(alignment: .leading, spacing: 1) {
            AppNameText(app: app)
                .fontWeight(.medium)
            if app.hasBackend {
                backendChip
            }
        }
        .frame(minWidth: goLinksEnabled ? 200 : 280, alignment: .leading)
    }

    /// (label, color, isWarning) for the backend's current state.
    private var backendStatus: (text: String, color: Color) {
        let isActive = app.isRunning || app.portStatus == .detached
        if app.hasBackend && !app.backendNeedsLocal && !app.backendBundled {
            return ("cloud", .secondary)            // hosted backend (Convex/Supabase cloud) — no local process
        }
        if app.backendUnstarted {
            return ("won't start", .orange)         // local backend nothing launches — the trap
        }
        if app.backendBundled {
            return (isActive ? "running" : "bundled", isActive ? .green : .secondary)
        }
        if app.needsSidecar {
            return (app.backendRunning ? "running" : "auto-start", app.backendRunning ? .green : .secondary)
        }
        return (isActive ? "running" : "idle", isActive ? .green : .secondary)
    }

    private var backendChip: some View {
        let status = backendStatus
        return HStack(spacing: 4) {
            Image(systemName: "server.rack")
                .font(.system(size: 8))
                .foregroundStyle(.tertiary)
            Text(app.backendKind?.label ?? "Backend")
                .foregroundStyle(.secondary)
            Text("·").foregroundStyle(.tertiary)
            Text(status.text)
                .foregroundStyle(status.color)
        }
        .font(.system(size: 10))
        .help(backendHelp)
    }

    private var backendHelp: String {
        guard let kind = app.backendKind else { return "" }
        var parts = ["\(kind.label) backend"]
        if app.backendBundled { parts.append("started by the dev script") }
        else if app.needsSidecar { parts.append("OpenPort runs \(app.backendCommand ?? "it") alongside the app") }
        else if app.backendUnstarted { parts.append("nothing starts it on Run — only the frontend will boot") }
        else if !app.backendNeedsLocal { parts.append("hosted in the cloud, no local process") }
        if let note = app.nodeNote { parts.append(note) }
        return parts.joined(separator: " · ")
    }

    private var hasMultiPortInfo: Bool {
        !app.extraPorts.isEmpty || app.hasBackend
    }

    private var multiPortDotColor: Color {
        if !app.extraPorts.isEmpty { return .green }
        if app.hasBackend && app.backendRunning { return .green }
        return .secondary.opacity(0.35)
    }

    private var knownPortCount: Int {
        Set(app.extraPorts.map(\.port) + [app.detectedPort ?? app.port]).count
    }

    private var multiPortDot: some View {
        Button { showPortsPopover.toggle() } label: {
            Circle()
                .fill(multiPortDotColor)
                .frame(width: 7, height: 7)
        }
        .buttonStyle(.plain)
        .help("\(knownPortCount) port\(knownPortCount == 1 ? "" : "s") — click to view")
        .popover(isPresented: $showPortsPopover, arrowEdge: .bottom) {
            MultiPortPopover(app: app)
        }
    }

    private var goLinkBadge: some View {
        Group {
            if editingGoAlias {
                HStack(spacing: 4) {
                    Text("go/")
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.secondary)
                    TextField("alias", text: $goAliasDraft)
                        .frame(width: 80)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                        .focused($goAliasFieldFocused)
                        .onSubmit { saveGoAlias() }
                        .onAppear { goAliasFieldFocused = true }
                        .onChange(of: goAliasFieldFocused) { _, focused in
                            if !focused { goAliasFieldFocused = true }
                        }
                    Button { saveGoAlias() } label: {
                        Image(systemName: "checkmark").font(.system(size: 10, weight: .bold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.green)
                    Button { editingGoAlias = false } label: {
                        Image(systemName: "xmark").font(.system(size: 10, weight: .bold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
            } else {
                Text(app.goAlias)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .onTapGesture {
                        goAliasDraft = app.goAlias
                        editingGoAlias = true
                    }
                    .help("Click to edit go/ alias")
            }
        }
        .frame(width: 210, alignment: .leading)
    }

    private func saveGoAlias() {
        model.updateGoAlias(for: app, alias: goAliasDraft)
        editingGoAlias = false
    }

    private func runInTerminalTab() {
        guard let root = model.portfolioRoot else { return }
        terminalStore.runInNewSession(title: app.folder,
                                      cwd: root.appendingPathComponent(app.folder),
                                      command: model.terminalCommand(for: app))
    }

    /// The OpenPort tab this row's server runs in, if it was started from one.
    private var servingTab: TerminalSession? {
        app.portStatus == .detached ? terminalStore.session(servingPort: activePort) : nil
    }

    private func openTerminalForApp() {
        if useExternalTerminal {
            model.openTerminal(for: app)
        } else if let root = model.portfolioRoot {
            terminalStore.openSession(title: app.folder, cwd: root.appendingPathComponent(app.folder))
        }
    }

    private var portBadge: some View {
        Group {
            if editingPort {
                HStack(spacing: 4) {
                    VStack(spacing: 0) {
                        Button { nudgePort(by: 1) } label: {
                            Image(systemName: "chevron.up").font(.system(size: 8, weight: .bold))
                        }
                        .buttonStyle(.plain)
                        Button { nudgePort(by: -1) } label: {
                            Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
                        }
                        .buttonStyle(.plain)
                    }
                    .foregroundStyle(.secondary)
                    TextField("", text: $portDraft)
                        .frame(width: 52)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(portConflict ? .red : .primary)
                        .focused($portFieldFocused)
                        .onSubmit { savePort() }
                        .scrollWheelHandler { delta in nudgePort(by: delta > 0 ? 1 : -1) }
                        .onChange(of: portDraft) { _, _ in portConflict = false }
                        .onAppear { portFieldFocused = true }
                        .onChange(of: portFieldFocused) { _, focused in
                            if !focused { portFieldFocused = true }
                        }
                    Button { savePort() } label: {
                        Image(systemName: "checkmark").font(.system(size: 10, weight: .bold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(portConflict ? .red : .green)
                    Button { editingPort = false } label: {
                        Image(systemName: "xmark").font(.system(size: 10, weight: .bold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
            } else {
                HStack(spacing: 5) {
                    Text(verbatim: "\(app.detectedPort ?? app.port)")
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(app.portStatus == .external ? Color.orange : .secondary)
                        .onTapGesture {
                            guard portIsEditable else { return }
                            portDraft = "\(app.port)"
                            editingPort = true
                        }
                        .help(portHelp)
                    if hasMultiPortInfo { multiPortDot }
                }
            }
        }
        .frame(width: 90, alignment: .leading)
    }

    /// A port declared in openport.json isn't ours to change: the project's command binds it
    /// literally, and we'd only overwrite the edit on the next scan.
    private var portIsEditable: Bool {
        !app.isRunning && app.portStatus != .detached && app.declaredPort == nil
    }

    private var portHelp: String {
        if app.declaredPort != nil { return "Port is set in this project's openport.json" }
        if app.isRunning || app.portStatus == .detached { return "Stop the server to change its port" }
        return "Click to edit port"
    }

    private func savePort() {
        guard let port = Int(portDraft), PortStore.isValid(port) else { portConflict = true; return }
        if takenPorts.contains(port) {
            portConflict = true
            return
        }
        model.updatePort(for: app, port: port)
        editingPort = false
    }

    private func nudgePort(by delta: Int) {
        var next = (Int(portDraft) ?? app.port) + delta
        while takenPorts.contains(next) { next += delta }
        portDraft = "\(min(max(next, 1), 65535))"
    }

    /// Live truth about the server, not about what we asked for. "starting" carries a
    /// relative timestamp because the useful question during a slow Convex boot is
    /// "is it 5 seconds in or stuck for 2 minutes?"
    private var statusBadge: some View {
        Group {
            switch app.portStatus {
            case .starting:
                HStack(spacing: 5) {
                    ProgressView().controlSize(.mini)
                    if let started = app.startedAt {
                        Text("starting · \(Text(started, style: .relative))")
                    } else {
                        Text("starting…")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .help("Process is up, waiting for the port to answer. The browser opens itself when it does.")
            case .running:
                Label("running", systemImage: "circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
                    .help("Serving on port \(app.detectedPort ?? app.port)")
            case .detached:
                if let tab = servingTab {
                    Button { terminalStore.select(tab.id) } label: {
                        Label("tab ↗", systemImage: "circle.fill")
                    }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(.green)
                    .help("Running in the “\(tab.title)” tab — click to open it")
                } else {
                    Label("terminal", systemImage: "circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                        .help("Running, but started outside OpenPort (e.g. from a terminal)")
                }
            case .crashed:
                Label("crashed", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .help(app.crashLog != nil ? "The process exited unexpectedly — click ⚠ next to Stop for the log" : "The process exited unexpectedly")
            case .external:
                Label("port busy", systemImage: "circle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .help("Another project is using port \(app.port)")
            case .free:
                // A stopped row's status cell is dead space — on hover it becomes the
                // archive control, so decluttering never means a trip to Settings.
                if isHovered {
                    Button { model.archive(app: app) } label: {
                        Label("archive", systemImage: "archivebox")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Hide this project in the Archived section at the bottom of the list")
                } else {
                    Text("—").foregroundStyle(.tertiary).font(.caption)
                }
            }
        }
        .frame(width: 110, alignment: .leading)
    }

    private var activePort: Int { app.detectedPort ?? app.port }
    /// Browser/copy/QR only make sense once something actually answers on the port —
    /// during .starting they'd hand out a dead URL.
    private var isActive: Bool { app.portStatus == .running || app.portStatus == .detached }

    private var actionButtons: some View {
        HStack(spacing: 8) {
            if app.isRunning || app.portStatus == .detached || app.portStatus == .crashed {
                Button { model.restart(app: app) } label: {
                    Image(systemName: "arrow.clockwise.circle.fill")
                }
                .help("Restart — stop, wait for the ports to free, start again")
                .buttonStyle(.plain)
                .foregroundStyle(.orange)
            }

            if isActive {
                if showActionBrowser {
                    Button {
                        SystemClient.openBrowser(port: activePort)
                    } label: {
                        Image(systemName: "globe")
                    }
                    .help("Open in browser")
                    .buttonStyle(.plain)
                    .foregroundStyle(.blue)
                }

                if showActionCopy {
                    Button {
                        SystemClient.copyNetworkURL(port: activePort)
                        copied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                    } label: {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    }
                    .help(copied ? "Copied!" : "Copy network URL (for other devices)")
                    .buttonStyle(.plain)
                    .foregroundStyle(copied ? .green : .secondary)
                    .animation(.easeInOut(duration: 0.2), value: copied)
                }

                if showActionQR {
                    Button { showQR = true } label: {
                        Image(systemName: "qrcode")
                    }
                    .help("Show QR code to open on another device")
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .popover(isPresented: $showQR, arrowEdge: .bottom) {
                        QRPopover(port: activePort)
                    }
                }
            }

            if showActionLogs && app.isRunning {
                Button { showLogs = true } label: {
                    Image(systemName: "doc.text.magnifyingglass")
                }
                .help("View live logs")
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }

            if showActionTerminal {
                Button { openTerminalForApp() } label: {
                    Image(systemName: "terminal")
                }
                .help(useExternalTerminal ? "Open in Terminal.app" : "Open terminal tab here")
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }

            if showActionEditor {
                Button { model.openEditor(for: app) } label: {
                    Image(systemName: "chevron.left.forwardslash.chevron.right")
                }
                .help("Open in VS Code")
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }

            if showActionFinder {
                Button { model.openFinder(for: app) } label: {
                    Image(systemName: "folder")
                }
                .help("Open in Finder")
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var startStopButton: some View {
        if app.isRunning || app.portStatus == .crashed || app.portStatus == .detached {
            HStack(spacing: 4) {
                Button {
                    if let tab = servingTab {
                        tab.interrupt()
                        model.stopAfterInterrupt(app: app)
                    } else {
                        model.stop(app: app)
                    }
                } label: {
                    Image(systemName: "stop.circle.fill")
                        .font(.system(size: 16))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.red)
                .help(servingTab != nil ? "Stop — sends Ctrl-C to its terminal tab" : "Stop server")

                if app.portStatus == .crashed, app.crashLog != nil {
                    Button { showCrashLog = true } label: {
                        Image(systemName: "exclamationmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(.orange)
                    }
                    .buttonStyle(.plain)
                    .help("Why did this fail?")
                    .popover(isPresented: $showCrashLog, arrowEdge: .trailing) {
                        CrashLogPopover(appName: app.name, log: app.crashLog ?? "")
                    }
                }
            }
            .frame(width: 28)
        } else {
            Button { model.start(app: app) } label: {
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 16))
            }
            .buttonStyle(.plain)
            .foregroundStyle(app.portStatus == .external ? Color.secondary : Color.green)
            .disabled(app.portStatus == .external)
            .help(app.portStatus == .external ? "Port \(app.port) is in use — change the port first" : "Start server")
            .frame(width: 28)
        }
    }
}

struct LogsSheet: View {
    let app: DevApp
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var logText: String = ""
    @State private var search: String = ""
    @State private var autoScroll: Bool = true
    @State private var timer: Timer?

    private var filteredLines: [(Int, String)] {
        let allLines = logText.components(separatedBy: "\n")
        if search.isEmpty {
            return Array(allLines.enumerated())
        }
        return allLines.enumerated().filter { _, line in
            line.range(of: search, options: .caseInsensitive) != nil
        }
    }

    private var displayText: String {
        if search.isEmpty {
            return logText
        }
        return filteredLines.map(\.1).joined(separator: "\n")
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            logBody
            Divider()
            footer
        }
        .frame(minWidth: 820, idealWidth: 1100, maxWidth: .infinity,
               minHeight: 480, idealHeight: 680, maxHeight: .infinity)
        .onAppear {
            refresh()
            timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
                Task { @MainActor in refresh() }
            }
        }
        .onDisappear {
            timer?.invalidate()
            timer = nil
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "doc.text.magnifyingglass")
                .foregroundStyle(.secondary)
            Text(app.name)
                .font(.headline)
            Text("· logs")
                .font(.headline)
                .foregroundStyle(.secondary)

            Spacer()

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("Filter", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 240)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var logBody: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if displayText.isEmpty {
                    Text(search.isEmpty ? "Waiting for output…" : "No matches.")
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text(verbatim: displayText)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .textSelection(.enabled)
                    Color.clear.frame(height: 1).id("__bottom__")
                }
            }
            .background(Color(nsColor: .textBackgroundColor))
            .onChange(of: logText) { _, _ in
                if autoScroll && search.isEmpty {
                    proxy.scrollTo("__bottom__", anchor: .bottom)
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 14) {
            let lineCount = logText.isEmpty ? 0 : logText.components(separatedBy: "\n").count
            let matchCount = filteredLines.count
            Text(search.isEmpty
                 ? "\(lineCount) line\(lineCount == 1 ? "" : "s")"
                 : "\(matchCount) of \(lineCount) match\(matchCount == 1 ? "" : "es")")
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()

            Toggle(isOn: $autoScroll) {
                Text("Auto-scroll").font(.caption)
            }
            .toggleStyle(.switch)
            .controlSize(.mini)
            .help("Auto-scroll to newest log line")

            Divider().frame(height: 16)

            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(logText, forType: .string)
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Copy all logs to clipboard")

            Button {
                model.clearLog(for: app)
                refresh()
            } label: {
                Label("Clear", systemImage: "trash")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.red.opacity(0.85))
            .help("Clear log buffer")

            Divider().frame(height: 16)

            Button("Close") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func refresh() {
        logText = model.liveLog(for: app) ?? ""
    }
}

struct MultiPortPopover: View {
    let app: DevApp

    private var primaryPort: Int { app.detectedPort ?? app.port }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("\(app.name) — bound ports")
                .font(.headline)
            Divider()

            portRow(port: primaryPort, command: app.runTarget?.command, isPrimary: true)

            ForEach(app.extraPorts) { extra in
                portRow(port: extra.port, command: extra.command, isPrimary: false)
            }

            if let kind = app.backendKind {
                Divider().padding(.vertical, 2)
                backendSection(kind: kind)
            }
        }
        .padding(14)
        .frame(width: 380)
    }

    @ViewBuilder
    private func backendSection(kind: BackendKind) -> some View {
        let isActive = app.isRunning || app.portStatus == .detached
        let (statusText, statusColor, running): (String, Color, Bool) = {
            if kind == .supabase && !app.backendNeedsLocal { return ("cloud — no local process", .secondary, false) }
            if app.backendUnstarted { return ("not started — only the frontend runs", .orange, false) }
            if app.backendBundled { return (isActive ? "running (started by dev)" : "starts with dev", isActive ? .green : .secondary, isActive) }
            if app.needsSidecar { return (app.backendRunning ? "running (auto-started)" : "auto-starts with app", app.backendRunning ? .green : .secondary, app.backendRunning) }
            return (isActive ? "running" : "idle", isActive ? .green : .secondary, isActive)
        }()

        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle()
                    .fill(running ? Color.green : statusColor.opacity(0.4))
                    .frame(width: 6, height: 6)
                Text("\(kind.label) backend")
                    .font(.caption)
                    .fontWeight(.medium)
                Spacer()
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(statusColor)
            }
            if let command = app.backendCommand {
                Text(command)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            if let note = app.nodeNote {
                Text(note)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    @ViewBuilder
    private func portRow(port: Int, command: String?, isPrimary: Bool) -> some View {
        HStack(spacing: 8) {
            Text(verbatim: "\(port)")
                .font(.system(.body, design: .monospaced))
                .fontWeight(isPrimary ? .semibold : .regular)
                .frame(width: 56, alignment: .leading)

            VStack(alignment: .leading, spacing: 1) {
                if isPrimary {
                    Text("primary")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                } else if let command, !command.isEmpty {
                    Text(command)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer(minLength: 4)

            Button {
                SystemClient.openBrowser(port: port)
            } label: {
                Image(systemName: "globe").font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.blue)
            .help("Open in browser")

            Button {
                SystemClient.copyNetworkURL(port: port)
            } label: {
                Image(systemName: "doc.on.doc").font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Copy network URL")
        }
    }
}

/// "nudge" for a plain project; "nudge:hubspot" with the instance dimmed for one of several
/// declared targets, so siblings read as one project at a glance.
struct AppNameText: View {
    let app: DevApp

    var body: some View {
        if let instance = app.instance {
            Text(app.folder).foregroundStyle(.primary)
                + Text(":\(instance)").foregroundStyle(.secondary)
        } else {
            Text(app.name).foregroundStyle(.primary)
        }
    }
}

struct CrashLogPopover: View {
    let appName: String
    let log: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(.orange)
                Text("\(appName) — crash output")
                    .font(.headline)
            }
            Divider()
            ScrollView {
                Text(log)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(maxHeight: 320)
        }
        .padding(16)
        .frame(width: 520)
    }
}

struct GoAliasPopover: View {
    @Binding var alias: String
    let onSave: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Browser shortcut")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 4) {
                Text("go/")
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)
                TextField("alias", text: $alias)
                    .frame(width: 160)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .onSubmit { onSave() }
            }
            HStack {
                Spacer()
                Button("Save", action: onSave)
                    .keyboardShortcut(.return)
            }
        }
        .padding(14)
        .frame(width: 300)
    }
}

struct QRPopover: View {
    let port: Int

    private var networkURL: String {
        "http://\(SystemClient.lanIPAddress()):\(port)"
    }

    private var qrImage: Image? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(networkURL.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let ciImage = filter.outputImage else { return nil }
        let scaled = ciImage.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        let context = CIContext()
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: scaled.extent.width, height: scaled.extent.height))
        return Image(nsImage: nsImage)
    }

    var body: some View {
        VStack(spacing: 10) {
            if let image = qrImage {
                image
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 180, height: 180)
            } else {
                Text("QR unavailable").foregroundStyle(.secondary)
            }
            Text(networkURL)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(width: 212)
    }
}
