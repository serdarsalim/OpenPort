import SwiftUI
import AppKit
import Combine
import ServiceManagement

@main
struct LocalhostApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup("OpenPort") {
            ContentView()
                .environmentObject(appDelegate.model)
                .environmentObject(appDelegate.terminalStore)
                .environmentObject(appDelegate.theme)
        }
        .windowResizability(.contentMinSize)

        Window("Settings", id: "settings") {
            SettingsView()
                .environmentObject(appDelegate.model)
                .environmentObject(appDelegate.terminalStore)
                .environmentObject(appDelegate.theme)
        }
        .windowResizability(.contentSize)

        Window("OpenPort — Help", id: "help") {
            HelpView()
        }
        .windowResizability(.contentMinSize)
    }
}

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let model = AppModel()
    let terminalStore = TerminalSessionStore()
    let theme = ThemeController()
    private var statusItem: NSStatusItem?
    private var cancellables = Set<AnyCancellable>()
    // The status poll mutates model.apps every few seconds; rebuilding the menu while the
    // user has it open would yank it shut mid-read. Defer until it closes.
    private var menuIsOpen = false
    private var pendingMenuRebuild = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        setupMenuBarIcon()

        // Reap leftover processes from a previous OpenPort session that quit without cleanup.
        model.reapPortfolioOrphans()

        model.$apps
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.rebuildMenu() }
            .store(in: &cancellables)

        model.$archivedNames
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.rebuildMenu() }
            .store(in: &cancellables)

        NotificationCenter.default
            .publisher(for: UserDefaults.didChangeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.rebuildMenu() }
            .store(in: &cancellables)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Synchronous SIGTERM → 500ms → SIGKILL on every spawned PID. Without this, children
        // get reparented to launchd (PPID=1) and outlive every future OpenPort launch invisibly.
        model.nukeAllSync()
    }

    private func setupMenuBarIcon() {
        rebuildMenu()
    }

    func menuWillOpen(_ menu: NSMenu) { menuIsOpen = true }

    func menuDidClose(_ menu: NSMenu) {
        menuIsOpen = false
        if pendingMenuRebuild {
            pendingMenuRebuild = false
            rebuildMenu()
        }
    }

    private func rebuildMenu() {
        let quickLaunch = UserDefaults.standard.bool(forKey: "menuBarQuickLaunch")

        // Remove icon entirely when quick launch is off
        guard quickLaunch else {
            statusItem = nil
            return
        }

        if menuIsOpen {
            pendingMenuRebuild = true
            return
        }

        if statusItem == nil {
            statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            statusItem?.button?.image = NSImage(systemSymbolName: "network", accessibilityDescription: "Localhost")
        }

        // Badge the icon with how many servers are up — the glance that answers
        // "is anything running?" without even opening the menu.
        let activeCount = model.activeApps.filter { $0.portStatus == .running || $0.portStatus == .detached }.count
        statusItem?.button?.title = activeCount > 0 ? " \(activeCount)" : ""
        statusItem?.button?.imagePosition = activeCount > 0 ? .imageLeading : .imageOnly

        let menu = NSMenu()
        menu.delegate = self

        let menuApps = model.activeApps
        if !menuApps.isEmpty {
            for app in menuApps {
                let isActive = app.isRunning || app.portStatus == .detached
                let canOpen = app.portStatus == .running || app.portStatus == .detached
                let port = app.detectedPort ?? app.port
                let appName = app.name
                let item = NSMenuItem()
                item.view = QuickLaunchMenuItemView(
                    name: appName,
                    port: port,
                    isRunning: isActive,
                    status: app.portStatus,
                    canOpenBrowser: canOpen,
                    onToggle: { [weak self] in
                        guard let self,
                              let target = self.model.apps.first(where: { $0.name == appName }) else { return }
                        if target.isRunning { self.model.stop(app: target) }
                        else { self.model.start(app: target) }
                        self.rebuildMenu()
                    },
                    onOpenBrowser: {
                        SystemClient.openBrowser(port: port)
                    }
                )
                menu.addItem(item)
            }
            menu.addItem(.separator())
        }

        menu.addItem(NSMenuItem(title: "Show OpenPort", action: #selector(showWindow), keyEquivalent: ""))

        let whatsNewItem = NSMenuItem(title: "What's new", action: #selector(showWhatsNew), keyEquivalent: "")
        whatsNewItem.target = self
        menu.addItem(whatsNewItem)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem?.menu = menu
    }

    @objc private func showWhatsNew() {
        showWindow()
        NotificationCenter.default.post(name: .openPortShowWhatsNew, object: nil)
    }

    @objc private func toggleApp(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String,
              let app = model.apps.first(where: { $0.name == name }) else { return }
        if app.isRunning { model.stop(app: app) } else { model.start(app: app) }
        rebuildMenu()
    }

    @objc private func showWindow() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first?.makeKeyAndOrderFront(nil)
    }
}

extension Notification.Name {
    static let openPortShowWhatsNew = Notification.Name("OpenPortShowWhatsNew")
}
