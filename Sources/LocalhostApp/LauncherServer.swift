import Foundation
import Network
import CoreImage
import AppKit

/// A minimal HTTP server that publishes a phone-friendly launcher page for every
/// dev app OpenPort knows about. Binds on all interfaces (0.0.0.0) so the page —
/// and the apps it links to — are reachable from any device on the same Wi-Fi.
///
/// Port 1453 is OpenPort's own standard port. (Editable below if it ever clashes.)
final class LauncherServer: @unchecked Sendable {
    static let port: UInt16 = 1453

    private var listener: NWListener?
    private(set) var isRunning = false

    private let lock = NSLock()
    private var apps: [LaunchAppInfo] = []
    private var lanIP: String = "localhost"

    /// Called when the phone taps Run / Stop. Set these before `start()`. They hop to
    /// the main actor inside AppModel, so they're safe to invoke from the network queue.
    var onStart: (@Sendable (String) -> Void)?
    var onStop: (@Sendable (String) -> Void)?

    func start() {
        guard !isRunning else { return }
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        guard let listener = try? NWListener(using: params, on: NWEndpoint.Port(rawValue: Self.port)!) else { return }
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }
        listener.start(queue: .global(qos: .utility))
        self.listener = listener
        self.isRunning = true
    }

    func stop() {
        listener?.cancel()
        listener = nil
        isRunning = false
    }

    /// Push the current app list + LAN IP. Called whenever OpenPort's state changes.
    func update(apps: [LaunchAppInfo], lanIP: String) {
        lock.lock()
        self.apps = apps
        self.lanIP = lanIP
        lock.unlock()
    }

    // MARK: - Connection handling

    private func handle(_ connection: NWConnection) {
        connection.start(queue: .global(qos: .utility))
        receive(on: connection, buffered: Data())
    }

    /// Read until the whole request is in. A phone's POST often sends the body in a second
    /// TCP segment; parsing only the first one meant Run silently did nothing.
    private func receive(on connection: NWConnection, buffered: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { connection.cancel(); return }
            var buffer = buffered
            if let data { buffer.append(data) }
            if !Self.isCompleteRequest(buffer), !isComplete, error == nil, buffer.count < 65536 {
                self.receive(on: connection, buffered: buffer)
                return
            }
            let request = String(decoding: buffer, as: UTF8.self)
            let (status, headers, body) = self.route(request)

            var head = "HTTP/1.1 \(status)\r\n"
            for (key, value) in headers { head += "\(key): \(value)\r\n" }
            head += "Content-Length: \(body.count)\r\nConnection: close\r\n\r\n"

            var out = Data(head.utf8)
            out.append(body)
            connection.send(content: out, completion: .contentProcessed { _ in connection.cancel() })
        }
    }

    private func route(_ request: String) -> (String, [(String, String)], Data) {
        let firstLine = request.components(separatedBy: "\r\n").first ?? ""
        let parts = firstLine.split(separator: " ")
        let method = parts.first.map(String.init) ?? "GET"
        let rawPath = parts.count >= 2 ? String(parts[1]) : "/"
        let path = rawPath.split(separator: "?").first.map(String.init) ?? "/"

        switch (method, path) {
        case ("GET", "/"):
            return ("200 OK",
                    [("Content-Type", "text/html; charset=utf-8"), ("Cache-Control", "no-store")],
                    Data(renderPage().utf8))

        case ("GET", "/healthz"):
            return ("200 OK", [("Content-Type", "text/plain")], Data("ok".utf8))

        case ("POST", "/start"), ("POST", "/stop"):
            // Any web page you visit can auto-submit a form to 127.0.0.1:1453 — a "simple"
            // cross-site POST gets no preflight. Browsers mark those with Origin and
            // Sec-Fetch-Site; our own page's forms are same-origin.
            guard Self.isSameOrigin(request) else {
                return ("403 Forbidden", [("Content-Type", "text/plain")], Data("Cross-site request refused".utf8))
            }
            // PRG: trigger the action, then redirect to a fresh GET so a refresh doesn't re-POST.
            let body = request.components(separatedBy: "\r\n\r\n").dropFirst().joined(separator: "\r\n\r\n")
            if let name = Self.formValue(body, key: "app") {
                if path == "/start" { onStart?(name) } else { onStop?(name) }
            }
            return ("303 See Other", [("Location", "/")], Data())

        default:
            return ("404 Not Found", [("Content-Type", "text/plain")], Data("Not found".utf8))
        }
    }

    private static func headers(of request: String) -> [String: String] {
        let head = request.components(separatedBy: "\r\n\r\n").first ?? ""
        var result: [String: String] = [:]
        for line in head.components(separatedBy: "\r\n").dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            result[key] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        return result
    }

    static func isCompleteRequest(_ data: Data) -> Bool {
        guard let end = data.range(of: Data("\r\n\r\n".utf8)) else { return false }
        let length = headers(of: String(decoding: data[..<end.upperBound], as: UTF8.self))["content-length"]
            .flatMap(Int.init) ?? 0
        return data.count - end.upperBound >= length
    }

    /// True unless the browser says this came from another site. Requests with no Origin
    /// (curl, older browsers on a same-origin form) pass; a mismatched Origin or a
    /// Sec-Fetch-Site of cross-site/same-site does not.
    static func isSameOrigin(_ request: String) -> Bool {
        let headers = headers(of: request)
        if let site = headers["sec-fetch-site"], site != "same-origin", site != "none" { return false }
        guard let origin = headers["origin"] else { return true }
        guard let host = headers["host"] else { return false }
        return origin == "http://\(host)"
    }

    private static func formValue(_ body: String, key: String) -> String? {
        for pair in body.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            guard kv.first.map(String.init) == key else { continue }
            let raw = kv.count > 1 ? String(kv[1]) : ""
            return raw.replacingOccurrences(of: "+", with: " ").removingPercentEncoding
        }
        return nil
    }

    // MARK: - Page rendering

    private func renderPage() -> String {
        lock.lock()
        let apps = self.apps
        let ip = self.lanIP
        lock.unlock()

        let haveLAN = ip != "localhost"
        let launcherURL = "http://\(ip):\(Self.port)"

        let rows = apps.map { app -> String in
            let runningLocal = SystemClient.isPortListening(app.port)
            let lanReachable = haveLAN && runningLocal && SystemClient.isPortListening(app.port, host: ip)
            let starting = app.isStarting && !runningLocal

            let dotClass: String
            let stateText: String
            if starting {
                dotClass = "local"; stateText = "starting…"
            } else if !runningLocal {
                dotClass = "stopped"; stateText = "stopped"
            } else if lanReachable {
                dotClass = "running"; stateText = "running"
            } else {
                dotClass = "local"; stateText = "localhost-only"
            }

            let name = Self.esc(app.name)
            let backend = app.backendLabel.map { " · \(Self.esc($0))" } ?? ""

            // Action: Open (when LAN-reachable) + Stop when up; Run when down.
            var actions = ""
            if starting {
                actions += Self.form(action: "/stop", app: app.name, label: "Stop", cls: "stop")
            } else if runningLocal {
                if lanReachable {
                    actions += "<a class=\"btn open\" href=\"http://\(ip):\(app.port)\" target=\"_blank\" rel=\"noopener\">Open ↗</a>"
                }
                actions += Self.form(action: "/stop", app: app.name, label: "Stop", cls: "stop")
            } else if app.isExternal {
                actions += "<span class=\"btn ghost\" title=\"Another process is on this port\">in use</span>"
            } else {
                actions += Self.form(action: "/start", app: app.name, label: "Run", cls: "run")
            }

            let hint = (runningLocal && !lanReachable)
                ? "<div class=\"hint\">bound to localhost — relaunch from OpenPort to expose it on the LAN</div>"
                : ""

            return """
            <li class="card">
              <div class="meta">
                <span class="dot \(dotClass)"></span>
                <div class="text">
                  <div class="name">\(name)</div>
                  <div class="sub"><span class="state \(dotClass)">\(stateText)</span> · :\(app.port)\(backend)</div>
                  \(hint)
                </div>
              </div>
              <div class="actions">\(actions)</div>
            </li>
            """
        }.joined(separator: "\n")

        let qr = Self.qrPNGBase64(for: launcherURL)
        let qrBlock = qr.map {
            "<img class=\"qr\" src=\"data:image/png;base64,\($0)\" alt=\"QR code for this launcher\" width=\"148\" height=\"148\">"
        } ?? ""

        let listOrEmpty = apps.isEmpty
            ? "<li class=\"empty\">No apps found. Pick a portfolio folder in OpenPort.</li>"
            : rows

        return """
        <!doctype html>
        <html lang="en">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
          <meta http-equiv="refresh" content="5">
          <title>OpenPort · Launcher</title>
          <style>
            :root {
              --bg:#f5f5f7; --card:#ffffff; --ink:#1d1d1f; --muted:#86868b; --line:#e3e3e6;
              --green:#30d158; --amber:#ff9f0a; --grey:#c4c4c8; --blue:#0a84ff; --red:#ff453a;
            }
            @media (prefers-color-scheme: dark) {
              :root {
                --bg:#000; --card:#1c1c1e; --ink:#f5f5f7; --muted:#98989d; --line:#2c2c2e;
                --grey:#48484a;
              }
            }
            * { box-sizing:border-box; -webkit-tap-highlight-color:transparent; }
            body {
              margin:0; background:var(--bg); color:var(--ink);
              font:16px/1.4 -apple-system,BlinkMacSystemFont,"SF Pro Text","Segoe UI",system-ui,sans-serif;
              padding:max(16px,env(safe-area-inset-top)) 16px calc(16px + env(safe-area-inset-bottom));
              -webkit-font-smoothing:antialiased;
            }
            .wrap { max-width:560px; margin:0 auto; }
            header { display:flex; align-items:baseline; justify-content:space-between; margin:6px 2px 16px; }
            h1 { font-size:22px; font-weight:700; margin:0; letter-spacing:-.01em; }
            .host { font:13px ui-monospace,"SF Mono",Menlo,monospace; color:var(--muted); }
            ul { list-style:none; margin:0; padding:0; display:flex; flex-direction:column; gap:10px; }
            .card {
              background:var(--card); border:1px solid var(--line); border-radius:14px;
              padding:13px 14px; display:flex; align-items:center; justify-content:space-between; gap:12px;
            }
            .meta { display:flex; align-items:center; gap:11px; min-width:0; }
            .dot { width:10px; height:10px; border-radius:50%; flex:none; background:var(--grey); }
            .dot.running { background:var(--green); box-shadow:0 0 0 4px color-mix(in srgb,var(--green) 22%,transparent); }
            .dot.local { background:var(--amber); }
            .dot.stopped { background:var(--grey); }
            .text { min-width:0; }
            .name { font-weight:600; font-size:16px; white-space:nowrap; overflow:hidden; text-overflow:ellipsis; }
            .sub { font:12px ui-monospace,"SF Mono",Menlo,monospace; color:var(--muted); margin-top:1px; }
            .state.running { color:var(--green); }
            .state.local { color:var(--amber); }
            .hint { font-size:11px; color:var(--amber); margin-top:3px; line-height:1.3; white-space:normal; }
            .actions { display:flex; gap:8px; flex:none; }
            form { margin:0; }
            .btn {
              display:inline-flex; align-items:center; justify-content:center;
              border:none; border-radius:10px; font-size:14px; font-weight:600;
              padding:9px 15px; cursor:pointer; text-decoration:none; font-family:inherit;
              min-height:38px;
            }
            .btn.open { background:var(--blue); color:#fff; }
            .btn.run  { background:var(--green); color:#04210d; }
            .btn.stop { background:color-mix(in srgb,var(--red) 16%,transparent); color:var(--red); }
            .btn.ghost{ background:transparent; color:var(--muted); border:1px solid var(--line); cursor:default; }
            .btn:active { transform:scale(.96); }
            .empty { color:var(--muted); text-align:center; padding:30px; }
            footer {
              margin-top:24px; padding-top:20px; border-top:1px solid var(--line);
              display:flex; flex-direction:column; align-items:center; gap:8px; text-align:center;
            }
            .qr { border-radius:12px; background:#fff; padding:8px; image-rendering:pixelated; }
            .footnote { font-size:12px; color:var(--muted); }
            .footnote code { font-family:ui-monospace,"SF Mono",Menlo,monospace; }
          </style>
        </head>
        <body>
          <div class="wrap">
            <header>
              <h1>OpenPort</h1>
              <span class="host">\(Self.esc(ip)):\(Self.port)</span>
            </header>
            <ul>
              \(listOrEmpty)
            </ul>
            <footer>
              \(qrBlock)
              <div class="footnote">Scan to open this launcher on another device</div>
              <div class="footnote"><code>\(Self.esc(launcherURL))</code></div>
            </footer>
          </div>
        </body>
        </html>
        """
    }

    // MARK: - Helpers

    /// Render a QR code for `string` as base64-encoded PNG bytes.
    private static func qrPNGBase64(for string: String, scale: CGFloat = 8) -> String? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(string.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let ci = filter.outputImage else { return nil }
        let scaled = ci.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let context = CIContext()
        guard let cg = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        let rep = NSBitmapImageRep(cgImage: cg)
        return rep.representation(using: .png, properties: [:])?.base64EncodedString()
    }

    private static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;")
         .replacingOccurrences(of: "\"", with: "&quot;")
         .replacingOccurrences(of: "'", with: "&#39;")
    }

    private static func form(action: String, app: String, label: String, cls: String) -> String {
        """
        <form method="post" action="\(action)"><input type="hidden" name="app" value="\(esc(app))"><button class="btn \(cls)" type="submit">\(esc(label))</button></form>
        """
    }
}

/// Immutable snapshot of one app, pushed from AppModel to the launcher server.
struct LaunchAppInfo: Sendable {
    let name: String
    let port: Int
    let isExternal: Bool       // another process holds the port — don't offer Run
    let isStarting: Bool       // Play pressed, port not answering yet — "starting…", not "stopped"
    let backendLabel: String?  // "Convex" / "Supabase", shown as a sub-label
}
