import SwiftUI
import AppKit
import SwiftTerm

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var terminalStore: TerminalSessionStore
    @EnvironmentObject private var theme: ThemeController
    @State private var dashboardSearch = ""

    var body: some View {
        Group {
            if model.portfolioRoot == nil {
                WelcomeView(model: model)
            } else {
                VStack(spacing: 0) {
                    TabBarView(store: terminalStore)
                    ZStack {
                        DashboardView(model: model, searchText: $dashboardSearch)
                            .opacity(terminalStore.selectedTab == .dashboard ? 1 : 0)
                            .allowsHitTesting(terminalStore.selectedTab == .dashboard)

                        ForEach(terminalStore.sessions) { session in
                            TerminalTabView(session: session)
                                .opacity(terminalStore.selectedTab == .session(session.id) ? 1 : 0)
                                .allowsHitTesting(terminalStore.selectedTab == .session(session.id))
                        }
                    }
                }
                .background(TitleBarMounter(terminalStore: terminalStore, dashboardSearch: $dashboardSearch))
            }
        }
        .frame(minWidth: 880, minHeight: 480)
        .preferredColorScheme(theme.resolvedScheme)
    }
}

/// Mounts NSTitlebarAccessoryViewControllers (leading + trailing) into the actual macOS
/// title bar so OpenPort's name and search field live alongside the traffic lights without
/// the fullSizeContentView/ignoresSafeArea fragility that breaks during window drag.
private struct TitleBarMounter: NSViewRepresentable {
    @ObservedObject var terminalStore: TerminalSessionStore
    @Binding var dashboardSearch: String

    func makeNSView(context: Context) -> NSView {
        let probe = WindowTrackingView()
        let store = terminalStore
        let binding = $dashboardSearch
        probe.onWindowChange = { window in
            guard let window else { return }
            Self.install(into: window, store: store, dashboardSearch: binding)
        }
        return probe
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    @MainActor private static let leadingID = NSUserInterfaceItemIdentifier("OpenPort.titleBar.leading")
    @MainActor private static let trailingID = NSUserInterfaceItemIdentifier("OpenPort.titleBar.trailing")

    @MainActor
    private static func install(into window: NSWindow, store: TerminalSessionStore, dashboardSearch: Binding<String>) {
        window.titleVisibility = .hidden
        let existing = Set(window.titlebarAccessoryViewControllers.compactMap(\.identifier))

        if !existing.contains(leadingID) {
            let host = NSHostingView(rootView:
                Text("OpenPort")
                    .font(.headline)
                    .fontWeight(.bold)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
            )
            host.frame = NSRect(x: 0, y: 0, width: 90, height: 28)
            let leading = NSTitlebarAccessoryViewController()
            leading.identifier = leadingID
            leading.layoutAttribute = .leading
            leading.view = host
            window.addTitlebarAccessoryViewController(leading)
        }

        if !existing.contains(trailingID) {
            let host = NSHostingView(rootView:
                TitleBarTrailing(terminalStore: store, dashboardSearch: dashboardSearch)
            )
            host.frame = NSRect(x: 0, y: 0, width: 280, height: 32)
            let trailing = NSTitlebarAccessoryViewController()
            trailing.identifier = trailingID
            trailing.layoutAttribute = .trailing
            trailing.view = host
            window.addTitlebarAccessoryViewController(trailing)
        }
    }
}

/// NSView subclass that fires a callback when it enters a window. More reliable than
/// dispatching to main from makeNSView, which can run before the view is in the hierarchy.
private final class WindowTrackingView: NSView {
    var onWindowChange: ((NSWindow?) -> Void)?
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onWindowChange?(window)
    }
}

/// Reactive trailing accessory: rebuilds the search binding/placeholder/active-session as
/// terminalStore changes. Hosted via NSHostingView so the SwiftUI tree stays alive.
private struct TitleBarTrailing: View {
    @ObservedObject var terminalStore: TerminalSessionStore
    @Binding var dashboardSearch: String

    private var activeSession: TerminalSession? {
        if case .session(let id) = terminalStore.selectedTab {
            return terminalStore.sessions.first { $0.id == id }
        }
        return nil
    }

    private var searchPlaceholder: String {
        if let session = activeSession {
            return "Find in terminal — \(session.title)"
        }
        return "Find apps"
    }

    private var searchBinding: Binding<String> {
        if let session = activeSession {
            return Binding(
                get: { session.query },
                set: { newValue in
                    session.query = newValue
                    if newValue.isEmpty {
                        session.terminalView.clearSearch()
                    } else {
                        session.terminalView.findNext(newValue)
                    }
                }
            )
        }
        return $dashboardSearch
    }

    var body: some View {
        SearchToolbarItem(
            placeholder: searchPlaceholder,
            text: searchBinding,
            session: activeSession
        )
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }
}

struct SearchToolbarItem: View {
    let placeholder: String
    @Binding var text: String
    let session: TerminalSession?
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            if let session, !session.query.isEmpty {
                Button {
                    session.terminalView.findPrevious(session.query)
                } label: {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Previous match")

                Button {
                    session.terminalView.findNext(session.query)
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Next match")
            }

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                TextField(placeholder, text: $text)
                    .textFieldStyle(.plain)
                    .focused($focused)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(0.07))
            )
            .frame(width: 240)
            .contentShape(Rectangle())
            .onTapGesture { focused = true }
        }
    }
}

struct WelcomeView: View {
    let model: AppModel

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "network")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("OpenPort")
                .font(.title)
                .fontWeight(.semibold)
            Text("Pick your portfolio root folder to get started.")
                .foregroundStyle(.secondary)
            Button("Choose Folder") {
                pickFolder(model: model)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct DashboardView: View {
    @ObservedObject var model: AppModel
    @Binding var searchText: String
    @EnvironmentObject private var theme: ThemeController
    @Environment(\.openWindow) private var openWindow
    @State private var showWhatsNew = false
    @State private var showLauncher = false
    @AppStorage("goLinksEnabled") private var goLinksEnabled = false
    @AppStorage("launcherEnabled") private var launcherEnabled = false
    @AppStorage("lastSeenChangelogVersion") private var lastSeenChangelogVersion = ""

    private var hasUnseenChangelog: Bool {
        lastSeenChangelogVersion != Changelog.latestVersion
    }

    private var filteredApps: [DevApp] {
        guard !searchText.isEmpty else { return model.activeApps }
        return model.activeApps.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    private var appearanceBinding: Binding<ThemeMode> {
        Binding(get: { theme.mode }, set: { theme.setMode($0) })
    }

    var body: some View {
        VStack(spacing: 0) {
            if model.apps.isEmpty && !model.isLoading {
                ContentUnavailableView(
                    "No apps found",
                    systemImage: "folder.badge.questionmark",
                    description: Text("No directories with a \(Text("\"dev\"").monospaced()) script found.")
                )
            } else {
                appTable
            }
            Divider()
            footer
        }
        .task { await model.refresh() }
        .sheet(isPresented: $showWhatsNew, onDismiss: {
            lastSeenChangelogVersion = Changelog.latestVersion
        }) {
            WhatsNewSheet()
        }
        .onReceive(NotificationCenter.default.publisher(for: .openPortShowWhatsNew)) { _ in
            showWhatsNew = true
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Button("Stop All") { model.stopAll() }
                .foregroundStyle(.red)

            Divider().frame(height: 14).padding(.horizontal, 4)

            Button { Task { await model.refresh() } } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .keyboardShortcut("r", modifiers: .command)
            .help("Refresh (⌘R)")

            ProgressView()
                .scaleEffect(0.55)
                .opacity(model.isLoading ? 1 : 0)

            Spacer()

            Button { showLauncher.toggle() } label: {
                Image(systemName: "wifi")
            }
            .buttonStyle(.plain)
            .foregroundStyle(launcherEnabled ? Color.green : .secondary)
            .help(launcherEnabled ? "LAN Launcher — on" : "LAN Launcher")
            .popover(isPresented: $showLauncher, arrowEdge: .bottom) {
                LauncherPopover(model: model)
            }

            footerIcon("questionmark.circle", help: "Help") { openWindow(id: "help") }

            ZStack(alignment: .topTrailing) {
                footerIcon("gearshape", help: "Settings") { openWindow(id: "settings") }
                if hasUnseenChangelog {
                    Circle()
                        .fill(Color.blue)
                        .frame(width: 6, height: 6)
                        .offset(x: 3, y: -2)
                        .help("New since you last looked — open Settings to see What's new")
                }
            }

            Menu {
                Picker("Appearance", selection: appearanceBinding) {
                    ForEach(ThemeMode.allCases) { mode in
                        Label(mode.label, systemImage: mode.symbol).tag(mode)
                    }
                }
                .pickerStyle(.inline)
            } label: {
                Image(systemName: theme.mode.symbol)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .foregroundStyle(.secondary)
            .help("Appearance — \(theme.mode.label)")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private func footerIcon(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(help)
    }

    private var appTable: some View {
        List {
            HStack(spacing: 14) {
                Color.clear.frame(width: 28)  // play/stop button
                Text("App")
                    .frame(minWidth: goLinksEnabled ? 200 : 280, alignment: .leading)
                if goLinksEnabled {
                    Text("go/ link")
                        .frame(width: 210, alignment: .leading)
                }
                Text("Port")
                    .frame(width: 90, alignment: .leading)
                Text("Status")
                    .frame(width: 110, alignment: .leading)
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .font(.caption)
            .fontWeight(.medium)
            .foregroundStyle(.tertiary)
            .listRowInsets(EdgeInsets())
            .listRowSeparator(.hidden, edges: .top)
            .listRowSeparator(.visible, edges: .bottom)
            .listRowBackground(Color.clear)
            .allowsHitTesting(false)

            ForEach(filteredApps) { app in
                AppRowView(app: app, model: model)
                    .listRowSeparator(.visible)
            }

            if !model.archivedApps.isEmpty {
                archivedHeader
                if archivedExpanded {
                    ForEach(model.archivedApps) { app in
                        ArchivedRowView(app: app, model: model)
                            .listRowSeparator(.visible)
                    }
                }
            }

            if !model.orphans.isEmpty {
                otherPortsHeader
                ForEach(model.orphans) { orphan in
                    OrphanRowView(orphan: orphan, model: model)
                        .listRowSeparator(.visible)
                }
            }
        }
        .listStyle(.inset)
    }

    @AppStorage("archivedSectionExpanded") private var archivedExpanded = false

    private var archivedHeader: some View {
        Button { archivedExpanded.toggle() } label: {
            HStack(spacing: 6) {
                Image(systemName: archivedExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                Image(systemName: "archivebox")
                    .font(.caption)
                Text("Archived")
                Text("(\(model.archivedApps.count))")
                    .foregroundStyle(.tertiary)
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 10)
        .padding(.top, 14)
        .padding(.bottom, 4)
        .font(.caption)
        .fontWeight(.medium)
        .foregroundStyle(.secondary)
        .listRowInsets(EdgeInsets())
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
    }

    private var otherPortsHeader: some View {
        HStack(spacing: 6) {
            Image(systemName: "questionmark.circle")
                .font(.caption)
            Text("Other ports in use")
            Text("(\(model.orphans.count))")
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.top, 14)
        .padding(.bottom, 4)
        .font(.caption)
        .fontWeight(.medium)
        .foregroundStyle(.secondary)
        .listRowInsets(EdgeInsets())
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
        .allowsHitTesting(false)
    }
}

/// A folded-away project: just its name (it holds no port), with one click to bring it back. Deliberately
/// inert — no play button, no actions — so the archive reads as storage, not as a second list.
private struct ArchivedRowView: View {
    let app: DevApp
    @ObservedObject var model: AppModel
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 14) {
            Color.clear.frame(width: 28)
            Text(app.name)
                .foregroundStyle(.secondary)
            Spacer()
            if isHovered {
                Button { model.unarchive(app.name) } label: {
                    Label("Unarchive", systemImage: "tray.and.arrow.up")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Move back to the main list")
            }
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 10)
        .background(isHovered ? Color.primary.opacity(0.06) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .onHover { isHovered = $0 }
        .contextMenu {
            Button { model.unarchive(app.name) } label: {
                Label("Unarchive", systemImage: "tray.and.arrow.up")
            }
        }
    }
}

/// Footer popover for the LAN Launcher — toggle it on and grab the QR / URL to pull the
/// page up on a phone. Mirrors the Settings → LAN Launcher section; both bind the same key.
private struct LauncherPopover: View {
    @ObservedObject var model: AppModel
    @AppStorage("launcherEnabled") private var launcherEnabled = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "wifi").foregroundStyle(.secondary)
                Text("LAN Launcher").font(.headline)
                Spacer()
                Toggle("", isOn: $launcherEnabled)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
                    .onChange(of: launcherEnabled) { _, enabled in
                        model.setLauncherEnabled(enabled)
                    }
            }

            if launcherEnabled {
                Divider()
                QRPopover(port: Int(LauncherServer.port))
                Button("Open in browser") {
                    if let url = URL(string: model.launcherURL) { NSWorkspace.shared.open(url) }
                }
                .controlSize(.small)
                .frame(maxWidth: .infinity, alignment: .center)
                Text("Open any app from a phone or tablet on this Wi-Fi. Apps you Run are auto-exposed on the LAN.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Turn on to open your apps from your phone — one page, live status, tap to launch.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(width: 244)
    }
}

struct OrphanRowView: View {
    let orphan: OrphanPort
    @ObservedObject var model: AppModel
    @State private var isHovered = false
    @State private var showConfirm = false

    private var dirLabel: String {
        guard !orphan.directory.isEmpty else { return "—" }
        return (orphan.directory as NSString).lastPathComponent
    }

    private var isOutsidePortfolio: Bool {
        guard let root = model.portfolioRoot?.path else { return true }
        return !orphan.directory.hasPrefix(root)
    }

    var body: some View {
        HStack(spacing: 14) {
            Button {
                if isOutsidePortfolio { showConfirm = true } else { model.stopOrphan(orphan) }
            } label: {
                Image(systemName: "stop.circle.fill").font(.system(size: 14))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.red.opacity(0.8))
            .help("Stop process \(orphan.pid)")
            .frame(width: 28)
            .confirmationDialog(
                "Stop \(orphan.command) on port \(orphan.port)?",
                isPresented: $showConfirm,
                titleVisibility: .visible
            ) {
                Button("Stop process \(orphan.pid)", role: .destructive) {
                    model.stopOrphan(orphan)
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text(orphan.directory.isEmpty ? "(no working directory)" : orphan.directory)
            }

            Text(dirLabel)
                .fontWeight(.medium)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(minWidth: 200, alignment: .leading)

            Text(verbatim: "\(orphan.port)")
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 90, alignment: .leading)

            Text(orphan.command)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 12)

            Button {
                SystemClient.openBrowser(port: orphan.port)
            } label: {
                Image(systemName: "globe")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.blue)
            .help("Open in browser")

            Button {
                SystemClient.copyNetworkURL(port: orphan.port)
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Copy network URL")
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 10)
        .background(isHovered ? Color.primary.opacity(0.06) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .onHover { isHovered = $0 }
        .help(orphan.directory.isEmpty ? "Process \(orphan.pid)" : orphan.directory)
    }
}

struct WhatsNewSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("What's new")
                    .font(.title2)
                    .fontWeight(.semibold)
                Spacer()
            }
            .padding(.horizontal, 24)
            .padding(.top, 24)
            .padding(.bottom, 16)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    ForEach(Changelog.entries) { entry in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                Text(entry.version)
                                    .font(.system(.headline, design: .monospaced))
                                Text(entry.date)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(entry.items, id: \.self) { item in
                                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                                        Text("•")
                                            .foregroundStyle(.tertiary)
                                        Text(item)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()

            HStack {
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
        }
        .frame(width: 540, height: 520)
    }
}

@MainActor
func pickFolder(model: AppModel) {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = false
    panel.prompt = "Select"
    panel.message = "Select your portfolio root folder"
    if panel.runModal() == .OK, let url = panel.url {
        model.setPortfolioRoot(url)
    }
}
