import Foundation

struct ChangelogEntry: Identifiable {
    var id: String { version }
    let version: String
    let date: String
    let items: [String]
}

enum Changelog {
    /// Newest first. Bump the version when you ship and add an entry.
    /// Date format: yyyy-MM-dd.
    static let entries: [ChangelogEntry] = [
        ChangelogEntry(
            version: "1.7.0",
            date: "2026-10-09",
            items: [
                "Every stack gets its own row. A project whose openport.json lists two run targets now shows two rows (nudge:hubspot, nudge:native), each with its own Play, Stop, status, logs and crash detection. Before, Play could only start both together, and while hubspot was still booting the dashboard grabbed native's port and opened the browser on the wrong app.",
                "Terminal tabs say what they're running. A tab running npm run dev:hubspot in nudge reads \"nudge:hubspot :3012\" with a green dot. When it's idle it shows the folder you're in.",
                "Jump from a row to its tab. A server started in an OpenPort tab shows \"tab ↗\" in the status column, and clicking it takes you there. Stop sends that tab a Ctrl-C, so the project's own launcher shuts its stack down cleanly.",
                "Run in Terminal Tab (right-click a row) runs the row's command in a terminal tab, so you can watch the output and Ctrl-C it yourself.",
                "The terminal button on a row goes to an idle tab already open in that project instead of opening another one.",
                "A busy port no longer blocks Play. If something else is on an app's port, Play moves the app to the next free one and saves it. OpenPort never kills a process that isn't part of the project it's starting. Projects that pin their port in openport.json can't move, so the row names whatever is in the way.",
                "Pick up where you left off. If OpenPort closed (or crashed) with servers running, the next launch offers to start them again in one click.",
                "Archived projects give their port back. Unarchiving assigns a fresh one, and the archive list no longer shows ports. Archive moved to the right-click menu only; it no longer appears in the status column on hover.",
                "Servers that only listen on IPv6 localhost (Vite's default on recent Node) are now seen as running instead of flickering between running and starting.",
                "Stop no longer kills your browser. It used to kill anything connected to the port, including the tab you had open on it.",
                "Quitting OpenPort now cleans up properly. Servers it started and anything running in its tabs go down with it, including grandchildren like next dev that used to survive on :3012 with nothing watching them.",
                "A start that's taking too long tells you. After 45 seconds the row turns into \"slow · logs\", shows the last log line on hover, and opens the logs on click.",
                "The LAN launcher refuses cross-site requests (any website could POST to it before), shows \"starting…\" instead of a dead Run button, and handles phones that send the form in two packets.",
                "Fixed several quieter bugs. Exited processes left log threads spinning. A Restart could get its new process torn down by the old one's exit. An out-of-range port crashed every launch. Auto-retry could loop forever. The launch cleanup could kill a tmux server started in a project folder. Stop All could hit unrelated processes on stopped rows' ports."
            ]
        ),
        ChangelogEntry(
            version: "1.6.0",
            date: "2026-08-14",
            items: [
                "Run is now honest — pressing Run shows \"starting\" with a live timer instead of claiming the app is up. A Convex + Next stack takes ~20 seconds to bind its port; OpenPort used to flag exactly that window as crashed. Crashed now means one thing only: the process actually died (and the log tells you why).",
                "The dashboard watches itself — statuses poll every few seconds, and every ~12s a full sweep adopts whatever port the server really bound and notices servers you started or stopped in a terminal. No more hitting refresh to learn the truth.",
                "Vite finally obeys its port — Vite ignores the PORT env var entirely, so a Vite app always booted on 5173 while OpenPort watched the assigned port. The port now travels as a --port flag (with --strictPort so collisions fail loudly), threaded through convex dev --start wrappers too. Framework detection also sees through npm-run indirection, so convex dev --start \"npm run dev:frontend\" is recognized as Vite.",
                "Opens when ready — after you press Run, the browser opens the app the moment its port answers, instead of you clicking the globe into a dead tab. Toggle in Settings → General.",
                "Status column replaces Git — starting / running / terminal / crashed / port busy, live. The Git column is gone (and with it a git call per project per refresh).",
                "Restart button — one click stops the app, waits until its ports are actually free, and starts it again. Works on crashed rows and terminal-started servers too. Clean Restart (right-click) still does the same plus a cache wipe.",
                "Menu bar tells the truth at a glance — the icon shows a count of running servers, and each app in the quick-launch menu carries a live status dot (green running, orange starting, red crashed). The menu no longer rebuilds itself shut while you're reading it.",
                "Archive the projects you never open — hover a stopped row's status cell (or right-click any row) and hit archive. Archived projects fold into a collapsed section at the bottom of the list and disappear from the menu bar, go/ links, and the LAN launcher. Unarchive with one click from the same section. Archiving a running project stops it first.",
                "One automatic retry on early crash — a dev server that dies within a minute of Play (post-reboot load storms, a port briefly held by a dying predecessor) gets its ports swept and one silent restart. A second death is real and shows as crashed with the log. The retry budget resets whenever the app reaches running or you press Stop/Play yourself."
            ]
        ),
        ChangelogEntry(
            version: "1.5.0",
            date: "2026-07-27",
            items: [
                "openport.json — drop this file in a project root and OpenPort stops guessing what Run means. It's the fix for projects whose dev command hides behind a launcher script (node scripts/dev.mjs), where the port isn't in package.json for us to find: OpenPort would auto-assign a port, watch it forever, and flag the app as crashed while it was serving happily on a different one.",
                "One Run, several stacks — the \"run\" array can list more than one command. The first owns the row's port and status; the rest start with it and stop with it, each on its own port. A repo running two frontends against two backends now takes one click instead of two terminal tabs.",
                "Declared commands run verbatim — no port patching, no injected host flags. If you wrote it, that's what executes.",
                "A declared port outranks a stored one, so a project that picked up a wrong auto-assigned port corrects itself on the next scan. Declaring \"backend\" also settles the Convex/Supabase chip instead of leaving it to sniffing, and \"framework\" plus \"caches\" tell Clean Restart which build dirs to wipe (all of them, for a multi-stack repo)."
            ]
        ),
        ChangelogEntry(
            version: "1.4.0",
            date: "2026-06-24",
            items: [
                "Clean Restart — right-click any app and pick \"Clean Restart\" to stop it, delete its framework build cache, and start fresh in one move. This is the fix for the dev server that wedges on compile: port open, CPU pegged, but the page never loads, and a normal Stop→Run doesn't help because it reuses the same poisoned cache. OpenPort knows which cache to wipe per framework (Next's .next, Vite/SvelteKit's node_modules/.vite and .svelte-kit, CRA's node_modules/.cache), so you don't have to drop into a terminal and rm -rf it yourself.",
                "Plain Run stays fast — the cache is only cleared when you explicitly choose Clean Restart, so day-to-day launches don't pay a from-scratch rebuild."
            ]
        ),
        ChangelogEntry(
            version: "1.3.0",
            date: "2026-06-14",
            items: [
                "LAN Launcher — flip on the Wi-Fi icon in the footer (or Settings → LAN Launcher) and OpenPort serves a phone-friendly page at port 1453 that lists every app with a tap-to-open link built from your Mac's Wi-Fi IP, a live running / stopped / localhost-only dot per app, and Run / Stop buttons so you can start an app from your phone. Clicking the footer icon reveals a QR code pointing at the launcher itself, so you can pull it up on a device in the first place.",
                "Auto-expose on Run — while the launcher is on, apps you Run from OpenPort bind to all interfaces automatically (Vite --host, Next -H 0.0.0.0, CRA HOST=0.0.0.0), so the links actually work from your phone without editing each dev script. Apps already running bound to localhost are flagged \"localhost-only\" on the page with a nudge to relaunch from OpenPort.",
                "1453 — OpenPort's own standard port. You know why."
            ]
        ),
        ChangelogEntry(
            version: "1.2.1",
            date: "2026-06-12",
            items: [
                "Cloud Convex no longer mislabeled \"won't start\" — a project pointed at a *.convex.cloud dev or prod deployment now shows \"cloud\" like hosted Supabase, since its data lives in the cloud and there's no local process to launch. Only local deployments (CONVEX_DEPLOYMENT local:/anonymous:, or a localhost URL) still expect a backend process, so the warning fires only when it's real."
            ]
        ),
        ChangelogEntry(
            version: "1.2.0",
            date: "2026-06-10",
            items: [
                "Auto appearance — a new Light / Dark / Auto control where Auto follows the sun at your location, flipping to dark at local sunset and back at sunrise. No geolocation prompt; it derives your coordinates from the system timezone. Pick it from the appearance menu in the footer or Settings → General.",
                "Backend awareness — OpenPort now detects when a project has a Convex or Supabase backend, whether the dev script already starts it, and whether it's a local process or a cloud connection. Each row shows a backend line under the app name with live status, and warns when a local backend has nothing to start it.",
                "dev:backend sidecar — when a project splits its frontend and backend into separate scripts, Run starts both so the frontend doesn't boot alone with failing data calls.",
                "Node version pinning — respects a project's .nvmrc / .node-version when launching, and drops Convex projects to a compatible Node when your default is too new, so the local backend stops failing to deploy \"use node\" actions silently.",
                "Readable logs — the live logs viewer now strips ANSI color codes, so output (and especially errors when a server won't start) reads as clean plain text instead of [36m / [2m noise."
            ]
        ),
        ChangelogEntry(
            version: "1.1.0",
            date: "2026-05-07",
            items: [
                "In-app terminal tabs — click the terminal icon on any row (or the + in the tab bar) to open a real shell tab inside OpenPort, no more alt-tabbing to Terminal.app",
                "Context-aware search — the title-bar search filters apps on the Dashboard and finds in scrollback when you're on a terminal tab; ▲▼ jump between matches; per-tab query memory",
                "Terminal profiles — Settings → Terminal lets you pick a theme (System, Dark, Light, Solarized Dark/Light, Dracula, Nord) and font size; changes apply live to every open terminal",
                "Orphan reaper — process group kills + recursive descendant reap fix the EADDRINUSE bug after restart; dead OpenPort sessions no longer leak convex/next/esbuild zombies for days",
                "Settings reorganized — sidebar layout (General / go/ links / Terminal / Rows) instead of an ever-scrolling page; portfolio folder moved here from the footer",
                "Custom title bar — bold OpenPort flush left, soft search pill flush right, traffic lights in the same strip; no more icon-and-name duplication",
                "Footer cleanup — refresh + spinner now sit next to Stop All; help / settings / theme cluster on the right; the unseen-changelog blue dot now decorates the gear",
                "Use external Terminal.app toggle — Settings → Terminal lets you keep launching the row's terminal button into macOS Terminal.app if you prefer the old behavior"
            ]
        ),
        ChangelogEntry(
            version: "2026.05.05",
            date: "2026-05-05",
            items: [
                "Detect every $USER-owned listening port, not just node",
                "Show a green dot next to the port when an app is bound to multiple ports — click to see all of them with their command lines",
                "New \"Other ports in use\" section — surfaces dev servers you started outside OpenPort, with per-row stop",
                "Filter system processes (Tailscale, ssh tunnels, ControlCenter, etc.) out of \"Other ports\" so you can't accidentally kill them",
                "Settings → Action buttons: hide globe / copy / QR / terminal / VS Code / Finder per row",
                "Live logs viewer — modal sheet with search filter, auto-scroll, copy, and clear",
                "Cwd-based port matching: an app running on a different port than assigned now flips to detached and shows the actual port",
                "Settings: replaced checkboxes with macOS switches",
                "Settings and Help are now draggable, resizable windows instead of sheets",
                "Help redesigned with a sidebar, search, and 12 sections covering every feature"
            ]
        )
    ]

    static var latestVersion: String { entries.first?.version ?? "" }
}
