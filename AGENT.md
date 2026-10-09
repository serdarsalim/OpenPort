# OpenPort — Agent Instructions

## What this is

A native macOS app (Swift 6, SwiftUI, macOS 14+) that scans a portfolio folder for npm projects and lets you start/stop their dev servers, see git status, edit ports and go/ aliases, and open each project in the browser, terminal, VS Code, or Finder.

No Xcode. Built entirely with Swift Package Manager.

---

## Rules — do this after every code change

1. Commit all changes to main first
2. `./build-app.sh` — rebuilds the app AND auto-generates `Sources/LocalhostApp/AppVersion.swift` with the current Malaysia time (MYT). The version appears in the app footer.
3. Kill and relaunch: `pkill -x LocalhostApp 2>/dev/null; sleep 1; open "dist/OpenPort.app"`

   The running process is named **`LocalhostApp`** (the SPM product), not `OpenPort` — the
   bundle is what's called OpenPort. `pkill -x "OpenPort"` matches nothing and exits silently,
   and then `open` just fronts the instance that's already running, so you sit there testing
   the old build and wondering why your change didn't land. Verify with `pgrep -lx LocalhostApp`
   before and after: the PID must change.
4. Only commit + push + upload release when user says "push"

Do not ask. Just do it every time, in that order.

Build + relaunch one-liner (always use absolute path for open — shell cwd resets between commands):
```bash
cd /Users/slm/my-portfolio/localhost-3000 && bash build-app.sh 2>&1 | tail -4 && pkill -x LocalhostApp 2>/dev/null; sleep 1 && open "/Users/slm/my-portfolio/localhost-3000/dist/OpenPort.app" && sleep 2 && pgrep -lx LocalhostApp
```

Push one-liner (only when user says push):
```bash
cd /Users/slm/my-portfolio/localhost-3000 && git push && gh release upload v0.1.0 dist/openport-macos.zip --clobber -R serdarsalim/openport
```

---

## Build & run

```bash
swift build -c release      # compile only
./build-app.sh              # compile + bundle + sign → dist/Localhost 3000.app
open "dist/OpenPort.app"
```

---

## Project structure

```
Package.swift                        SPM config, Swift 6, macOS 14+
build-app.sh                         builds .app bundle, generates icon, ad-hoc signs, zips
AppIcon.png                          source icon (1024×1024), converted to .icns by build script
make-icon.swift                      generates AppIcon.png from SF Symbol

Sources/LocalhostApp/
  App.swift                          @main entry + AppDelegate (menu bar icon, Combine observers)
  Models.swift                       DevApp, GitStatus, PortStatus (Sendable structs)
  PortStore.swift                    load/save ports in UserDefaults (key: "appPorts")
  GoLinkStore.swift                  load/save go/ aliases in UserDefaults (key: "goLinks")
  AppScanner.swift                   scans portfolio root for dirs with package.json + "dev" script,
                                     reads openport.json when a project declares its own run targets
  ProcessManager.swift               @MainActor, starts/stops npm via /bin/zsh exec npm run dev
  GitClient.swift                    async git status checks via Task.detached shell calls
  SystemClient.swift                 open Terminal / VS Code / Finder / browser, copy LAN URL,
                                     detect external running servers via lsof
  ProxyServer.swift                  NWListener on port 9080, routes go/alias → localhost:PORT
  AppModel.swift                     @MainActor ObservableObject — all app logic
  ContentView.swift                  welcome screen + dashboard layout + column headers + footer
  AppRowView.swift                   per-app row: play/stop, name, go/alias, port, git, actions
  SettingsView.swift                 Settings sheet + GoLinksSetup (install/uninstall LaunchDaemon)
  HelpView.swift                     in-app help sheet
  ScrollWheelModifier.swift          NSViewRepresentable scroll wheel capture for port nudging
```

---

## Key decisions & gotchas

### openport.json — the project declares, we stop guessing

Every heuristic in `AppScanner` breaks the moment a project wraps its dev server in a
launcher script. `"dev": "node scripts/dev.mjs"` tells us nothing: not the port it binds,
not how many processes it starts, not whether the backend comes up with it. We used to
auto-assign a port, watch it forever, and paint the row `.crashed` while the app served
fine on a port we never looked at.

So a project can state it outright, in `openport.json` at its root:

```json
{
  "run": [
    { "name": "hubspot", "command": "npm run dev:hubspot", "port": 3012, "caches": [".next"] },
    { "name": "native",  "command": "npm run dev:native",  "port": 3013, "caches": [".next-native"],
      "backend": { "kind": "convex", "local": false } }
  ],
  "backend": { "kind": "convex", "bundled": true, "local": true },
  "framework": "next"
}
```

Rules that matter:

- **One run entry = one row.** A single target keeps the folder name (`randevu`). Several
  targets become sibling rows keyed `folder:name` (`nudge:hubspot`, `nudge:native`), each
  with its own Play/Stop, status, logs, crash detection and auto-retry. This replaced the old
  "first entry is primary, the rest are sidecars" model, where Play could only start both,
  a sidecar had no status of its own, and the primary's death took the sidecar with it.
- **`DevApp.name` is the row key, `DevApp.folder` is the directory.** Every path must come
  from `folder` — `root.appendingPathComponent(app.name)` is a bug for multi-target rows.
- **A declared port is the only port a row may claim.** `refresh()` hands a folder's lsof
  listeners to the sibling whose declared port matches; unmatched ones (nudge's local Convex
  on 3210/3211, its dashboard on 6790) go to the first sibling that's up, else to the orphan
  list. Sniffed (undeclared) rows keep the "adopt the lowest port in my folder" fallback for
  Vite-on-5173. Never let a declared row adopt a sibling's port: that's how Play once opened
  the browser on native's :3013 while hubspot was still booting.
- **Target-level `backend` and `caches` override the project-level ones.** A declared cache
  list replaces the framework default (clean-restarting native must not wipe `.next`, which
  hubspot is serving from).
- **First sibling inherits the folder's go/ alias** (go/nudge → hubspot); the rest default to
  `folder-name` (go/nudge-native). Colons never appear in default aliases.
- **Declared commands run verbatim.** No `patchPort`, no `applyHostBinding`. We can't parse
  a launcher script, so rewriting it is how we'd break it — which means `bindHost` (LAN
  launcher auto-expose) is skipped for declared projects. That's the trade for reliability.
- **A declared port outranks the store.** `PortStore.assign` overwrites a saved value from
  `declaredPorts`, so a project that once picked up a wrong auto-assignment self-corrects.
  Consequence: editing the port in the UI for a declared app doesn't stick.
- **`backend` is optional and total** — when present it replaces `detectBackend` sniffing
  outright (no merging). Absent, the old heuristics run unchanged.
- **Every key is optional and a malformed file falls back to sniffing**, never hides the
  project. Unknown keys are ignored, which is why `_comment` works. An unnamed target is
  named from its command (`CommandLabel`), duplicates get a numeric suffix.
- A project with `openport.json` and no `dev`/`dev:frontend` script still shows up.

Live examples: `nudge/openport.json` (two stacks), `randevu/openport.json` (one stack whose
port was invisible).

### Port persistence
`PortStore` uses `UserDefaults`. `defaults.dictionary(forKey:)` returns `[String: Any]` — cannot cast directly to `[String: Int]`. Always use `compactMapValues { $0 as? Int }`. This was a root-cause bug — don't revert it.

### Process spawning
Uses `/bin/zsh -c "exec npm run dev"` with PATH set to include `/opt/homebrew/bin:/usr/local/bin`. The `exec` replaces the shell so `process.terminate()` hits npm directly. Sets both `PORT` and `VITE_PORT` env vars.

### External server detection
`SystemClient.detectRunningServers()` runs two `lsof` calls: one for (pid→port) of listening node processes, one for (pid→cwd), matched by PID. Uses `DispatchSemaphore` with a 4-second timeout to prevent hangs. Detected external servers show as `.detached` status — Stop button sends `SIGTERM` to their PID.

### PortStatus enum
`.free` — stopped, port available
`.starting` — started by this app, process alive, port not bound yet
`.running` — started by this app, port listening
`.detached` — started externally, detected by lsof
`.external` — port in use by an unrelated process
`.crashed` — was started by app but stopped unexpectedly

Port number turns **orange** in the UI when status is `.external`.

**`.crashed` is owned by the ProcessManager termination handler alone.** Never mark crashed
from a port probe: a Convex + Next stack takes ~20s to bind its port, and "started but port
not listening" is `.starting`, not a crash. This misdiagnosis was the original "Play is
unreliable" bug.

### Status polling (AppModel)
`startPolling()` runs forever: every 3s it probes the ports of apps we started (raw
`connect()`, negligible); every 4th tick it calls `refresh(quiet: true)` — full lsof sweep
that adopts a mismatched real port into `detectedPort` and syncs rows for servers
started/stopped in a terminal. `refresh()` preserves `.crashed` + `crashLog` + `startedAt`
from the previous apps array — rebuilding the array must not amnesia away state that only
lives in it. `refreshInFlight` guards manual vs. quiet overlap.

### Auto-retry on early crash
A process that dies < 60s after Play gets its ports swept (children of the dead leader may
still hold them) and one silent restart (`autoRetried` set in AppModel). Second death →
`.crashed` with log. Budget resets on `.running` or manual Stop/Play (`start(isRetry:)`
distinguishes the retry path). Born from a real incident: a post-reboot load storm (load
avg 215 — Spotlight reindex + a parallel agent running fleet deploys) killed freshly
started dev servers; the projects were fine, the machine wasn't. OpenPort was correctly
reporting crashed — now it also recovers.

### Auto-open on ready
Play inserts the app into `pendingBrowserOpen`; the first poll/refresh that sees the port
answer opens the browser once (`openBrowserOnReady`, Settings → General, default on).
Crash/stop clears the pending flag so a failed boot doesn't open a dead tab later.

### Vite and ports — the one framework that ignores PORT
Vite reads neither `PORT` nor `VITE_PORT` (we still set both for apps whose config reads
them). For sniffed Vite projects the port travels as a CLI flag: `npm run dev -- --port N
--strictPort`, or — when the dev script wraps the frontend (`convex dev --start "npm run
dev:frontend"`) — the script body is run directly with the flag threaded into the quoted
inner command (`applyPortBinding`, wrapper-aware for both quote styles, npm-aware for
inner `npm run` commands). `--strictPort` makes a collision fail loudly in the logs
instead of silently drifting to 5173. Declared (openport.json) commands stay verbatim.

Framework sniffing sees through one level of `npm run X` indirection:
`AppScanner.expandScriptReferences` appends referenced script bodies into `sniffScript`
(detection only, never executed) — that's how `convex dev --start "npm run dev:frontend"`
with `"dev:frontend": "vite"` is recognized as Vite.

### No Git column
Removed deliberately (user never used it) along with GitClient — a git subprocess per
project per refresh was the most expensive part of refresh, untenable at a 12s auto-refresh
cadence. The column is now Status (starting/running/terminal/crashed/port busy), which is
what the user actually watches. Don't reintroduce git status.

### go/ links architecture
Three-layer stack:
1. `/etc/hosts` — adds `127.0.0.1 go` (one-time setup)
2. Python TCP forwarder as LaunchDaemon — listens on port 80, forwards to port 9080 (one-time setup, runs as root at boot)
3. `ProxyServer` (NWListener on 9080) — reads `/alias` from HTTP path, returns 302 to `http://localhost:PORT`

Setup is done via `osascript` with `with administrator privileges` — runs a shell script that writes the plist to `/Library/LaunchDaemons/` and loads it with `launchctl`. One-time only. Tracked via `@AppStorage("goLinksSystemSetup")`.

`GoLinkStore` saves `[appName: alias]` to UserDefaults key `"goLinks"`. Default alias is `appName.lowercased()`.

`ProxyServer` is path-based (not host-header-based). It reads the first path segment from the HTTP request line as the alias. Do not revert to host-header routing — it doesn't work because the browser sends `Host: 127.0.0.1:9080`, not `Host: alias.go`.

### Menu bar icon
`AppDelegate` holds `NSStatusItem?`. `rebuildMenu()` creates/destroys the status item based on `UserDefaults["menuBarQuickLaunch"]`. Two Combine subscribers trigger `rebuildMenu()`: one on `model.$apps`, one on `NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)`. The second one ensures toggling the setting in the UI immediately shows/hides the icon.

### Row layout (AppRowView)
Order: play/stop button → app name → go/ alias (if enabled) → port → git → Spacer → action buttons

Column widths (must stay in sync between AppRowView and the header row in ContentView):
- play/stop: 28px (header placeholder: `Color.clear.frame(width: 28)`)
- app name: minWidth 200 (go links on) / 280 (go links off)
- go/ alias: 210px
- port: 90px
- git: 70px

### Port/alias field focus
When editing a port or go/ alias inline, `onChange(of: fieldFocused)` reasserts focus if it drops. This prevents clicking outside from dismissing the editor — only ✓, ✕, or Enter can exit.

### Terminal button
Uses `open -a Terminal <path>`, not AppleScript. AppleScript requires entitlements the ad-hoc signed app doesn't have.

### Dark/light mode
Stored in `@AppStorage("colorScheme")` as `"light"` or `"dark"`. Toggle in footer cycles between the two.

### Signing
Ad-hoc only (`codesign --sign -`). No Apple Developer account needed. Users get a Gatekeeper warning on first launch; right-click → Open bypasses it.

### No Xcode project
Never add one. SPM only. No third-party dependencies.

---

## State flow

```
AppModel (@MainActor ObservableObject)
  ├── refresh() — scans folder, assigns ports, fetches git + port + external servers in parallel
  ├── start(app:) — ProcessManager.start → updates apps[].isRunning + refreshProxyRoutes()
  ├── stop(app:) — ProcessManager.stop or kill(pid, SIGTERM) → updates apps[] + refreshProxyRoutes()
  ├── stopAll() — stops all, updates all apps[]
  ├── updatePort(for:port:) — PortStore.save + updates apps[].port in memory
  ├── updateGoAlias(for:alias:) — GoLinkStore.setAlias + updates apps[].goAlias + refreshProxyRoutes()
  ├── setGoLinksEnabled(_:) — starts/stops ProxyServer + refreshProxyRoutes()
  └── refreshProxyRoutes() — builds [alias: port] dict → ProxyServer.updateRoutes()

PortStore — UserDefaults "appPorts" ([String: Int])
GoLinkStore — UserDefaults "goLinks" ([String: String])
ProcessManager — @MainActor, tracks [String: Process], crash detection via terminationHandler
ProxyServer — @unchecked Sendable, NWListener on 9080, NSLock for thread-safe routes
GitClient — static async, runs git via Task.detached
SystemClient — static, AppKit calls + lsof-based server detection
```

---

## GitHub

Repo: https://github.com/serdarsalim/openport
Release: v0.1.0 — asset `openport-macos.zip`
