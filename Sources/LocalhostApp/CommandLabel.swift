import Foundation

/// Turns a command line into the short name a person would call it by:
/// `npm run dev:hubspot` → "hubspot", `npx convex dev` → "convex",
/// `node scripts/dev-native.mjs` → "dev-native", `claude` → "claude".
///
/// Used for terminal tab titles and as the fallback name of an unnamed openport.json target.
enum CommandLabel {
    static func label(for command: String) -> String {
        var tokens = command.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        // Leading env assignments (`PORT=3000 npm run dev`) say nothing about what runs.
        while let first = tokens.first, isEnvAssignment(first) { tokens.removeFirst() }
        guard let head = tokens.first else { return command }
        let tool = (head as NSString).lastPathComponent
        let args = tokens.dropFirst().filter { !$0.hasPrefix("-") }

        switch tool {
        case "npm", "pnpm", "yarn", "bun":
            var rest = Array(args)
            if rest.first == "run" || rest.first == "run-script" { rest.removeFirst() }
            if rest.first == "exec" || rest.first == "x" || rest.first == "dlx" {
                return rest.dropFirst().first.map(binaryName) ?? tool
            }
            guard let script = rest.first else { return tool }
            return looksLikeFile(script) ? fileStem(script) : scriptLabel(script)
        case "npx", "bunx", "pnpx":
            return args.first.map(binaryName) ?? tool
        case "node", "tsx", "ts-node", "deno", "python", "python3", "ruby", "sh", "bash", "zsh":
            return args.first.map(fileStem) ?? tool
        default:
            return tool
        }
    }

    /// "dev:hubspot" → "hubspot"; any other script name is already the label.
    static func scriptLabel(_ script: String) -> String {
        if script.hasPrefix("dev:"), script.count > 4 { return String(script.dropFirst(4)) }
        return script
    }

    private static func isEnvAssignment(_ token: String) -> Bool {
        guard let eq = token.firstIndex(of: "="), eq != token.startIndex else { return false }
        return token[..<eq].allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }

    private static func looksLikeFile(_ token: String) -> Bool {
        token.contains("/") || [".js", ".mjs", ".cjs", ".ts", ".mts"].contains { token.hasSuffix($0) }
    }

    /// `convex@latest` → "convex", `@scope/tool@1` → "tool".
    private static func binaryName(_ token: String) -> String {
        let last = (token as NSString).lastPathComponent
        guard let at = last.dropFirst().firstIndex(of: "@") else { return last }
        return String(last[..<at])
    }

    private static func fileStem(_ token: String) -> String {
        ((token as NSString).lastPathComponent as NSString).deletingPathExtension
    }
}
