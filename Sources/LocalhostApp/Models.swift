import Foundation

enum PortStatus: Sendable, Hashable {
    case free      // stopped, port available
    case starting  // we started it, process alive, no port bound yet
    case running   // we started it, port is responding
    case detached  // running in this project's directory but started outside the app
    case external  // something else is on the assigned port (different project)
    case crashed   // we started it but it stopped responding
}

/// A managed backend that a project depends on alongside its frontend.
enum BackendKind: String, Sendable, Hashable {
    case convex
    case supabase

    var label: String {
        switch self {
        case .convex:   return "Convex"
        case .supabase: return "Supabase"
        }
    }
}

/// One dev server a project declares in `openport.json`.
///
/// This exists because guessing stops working once a project wraps its dev server in a
/// launcher script: we can't read `npm run dev` and know it boots two frontends and a
/// backend watcher. A declared target is run verbatim — we don't patch its port or inject
/// host flags, because the project already said exactly what it wants.
///
/// A project that declares several targets gets one dashboard row per target ("nudge ·
/// hubspot", "nudge · native"), each with its own Play, Stop, status, logs and crash
/// detection — two stacks are two things you run, not one.
struct RunTarget: Sendable, Hashable, Identifiable {
    var id: String { name }
    let name: String     // short label shown on the row ("hubspot", "native")
    let command: String  // run as-is in the project directory
    let port: Int?       // the port this target binds, when the project tells us
}

struct DevApp: Identifiable, Sendable, Hashable {
    var id: String { name }
    /// Unique row key: the folder name, or "folder:instance" for a project that declares
    /// several run targets. Keys ports, go/ aliases, archive state and the process table.
    let name: String
    /// The project folder under the portfolio root. Always use this for paths, never `name`.
    var folder: String
    /// The declared target's label when the folder has several ("hubspot"); nil otherwise.
    var instance: String? = nil
    var port: Int
    var isRunning: Bool
    var portStatus: PortStatus
    var detectedPort: Int?   // actual port the server bound to (may differ from assigned)
    var externalPID: Int32?  // PID of a detached process we can kill
    var goAlias: String      // alias used in go/<alias> routing
    var devScript: String?           // raw dev script string, used to patch port at launch
    var devScriptName: String?       // npm script name to invoke (e.g. "dev" or "dev:frontend")
    var sniffScript: String?         // devScript with `npm run X` references expanded — detection only, never run

    // Backend (Convex / Supabase) the project needs running with the frontend.
    var backendKind: BackendKind? = nil  // detected backend, if any
    var backendBundled: Bool = false     // the frontend dev script already starts the backend
    var backendNeedsLocal: Bool = false  // backend runs as a local process (Convex local / Supabase docker)
    var backendCommand: String? = nil    // sidecar command we run when the backend isn't bundled
    var backendRunning: Bool = false     // true when we've spawned the backend sidecar
    var nodeNote: String? = nil          // which Node we pin for this app (e.g. ".nvmrc → 20", "Convex compat")

    var hasBackend: Bool { backendKind != nil }
    /// We need to spawn the backend ourselves: it exists, isn't bundled into dev, runs locally,
    /// and we resolved a command for it.
    var needsSidecar: Bool { hasBackend && !backendBundled && backendNeedsLocal && backendCommand != nil }
    /// Backend exists and runs locally but nothing will start it on Run — the "only frontend" trap.
    var backendUnstarted: Bool { hasBackend && !backendBundled && backendNeedsLocal && backendCommand == nil }

    var crashLog: String? = nil     // last stderr output captured on unexpected exit
    /// What sits on this row's port when it's .external — "time-off (node)", "Docker (pid 812)".
    var portHolder: String? = nil
    /// A busy port only blocks Play when openport.json pins it. Anything else moves to the
    /// next free port instead of making you edit the number by hand.
    var canPlay: Bool { portStatus != .external || declaredPort == nil }
    var startedAt: Date? = nil      // when we pressed play — drives the "starting for Ns" hint
    var extraPorts: [DetectedPort] = [] // additional ports bound by this app's cwd

    // Declared in openport.json. nil means we fell back to reading package.json.
    var runTarget: RunTarget? = nil
    var declaredFramework: String? = nil   // overrides dev-script sniffing for cache clearing
    var declaredCaches: [String] = []      // build caches to wipe on a clean restart

    /// The project told us what Run means, so we stop inferring it.
    var isDeclared: Bool { runTarget != nil }
    /// A declared port is the only port this row may claim. Adopting "whatever else listens
    /// in this folder" is how a sibling's port got mistaken for this one.
    var declaredPort: Int? { runTarget?.port }
}

struct DetectedPort: Sendable, Hashable, Identifiable {
    var id: String { "\(pid):\(port)" }
    let pid: Int32
    let port: Int
    let command: String
}

struct OrphanPort: Identifiable, Sendable, Hashable {
    var id: String { "\(pid):\(port)" }
    let pid: Int32
    let port: Int
    let directory: String
    let command: String
}
