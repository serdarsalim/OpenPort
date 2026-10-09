import AppKit
import Combine
import Foundation
import SwiftTerm

@MainActor
final class TerminalSession: ObservableObject, Identifiable {
    let id = UUID()
    @Published var title: String
    @Published var query: String = ""
    let cwd: URL
    let terminalView: LocalProcessTerminalView
    private let delegateProxy: ProcessDelegate

    init(title: String, cwd: URL, onTerminated: @escaping (UUID) -> Void) {
        self.title = title
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
            if !trimmed.isEmpty { self.title = trimmed }
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
    @Published var sessions: [TerminalSession] = []
    @Published var selectedTab: TabSelection = .dashboard

    enum TabSelection: Equatable {
        case dashboard
        case session(UUID)
    }

    func openSession(title: String, cwd: URL) {
        let session = TerminalSession(title: title, cwd: cwd) { [weak self] id in
            Task { @MainActor in self?.handleProcessExit(id) }
        }
        sessions.append(session)
        selectedTab = .session(session.id)
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
        sessions.map { $0.terminalView.process.shellPid }.filter { $0 > 0 }
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
}
