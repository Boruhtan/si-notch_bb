import Foundation

/// Identifies the local host without reading process arguments or credentials.
public enum SessionOrigin {
    private static let terminals = [
        "apple_terminal": "com.apple.Terminal",
        "iterm.app": "com.googlecode.iterm2",
        "ghostty": "com.mitchellh.ghostty",
        "wezterm": "com.github.wez.wezterm",
        "vscode": "com.microsoft.VSCode",
        "warpterminal": "dev.warp.Warp-Stable",
        "rex": "com.superlogical.rex",
        "zed": "dev.zed.Zed"
    ]
    private static let knownBundles: Set<String> = Set(terminals.values).union([
        "com.microsoft.VSCodeInsiders", "com.todesktop.230313mzl4w4u92", "dev.zed.Zed",
        "dev.zed.Zed-Preview", "com.openai.codex", "net.kovidgoyal.kitty", "org.alacritty"
    ])

    public static func bundleID(environment: [String: String]) -> String? {
        guard environment["SSH_CONNECTION"] == nil, environment["SSH_TTY"] == nil else { return nil }
        if environment["REX_SESSION"]?.hasPrefix("session:") == true,
           environment["REX_BLOCK"]?.hasPrefix("block:") == true { return "com.superlogical.rex" }
        if let bundle = environment["__CFBundleIdentifier"], knownBundles.contains(bundle) { return bundle }
        return environment["TERM_PROGRAM"].flatMap { terminals[$0.lowercased()] }
    }

    public static func ancestorHost(executables: [String], home: String) -> String? {
        let applications = ["/Applications/", home + "/Applications/"]
        let rexServerRoot = home + "/Library/Application Support/com.superlogical.rex/RexServer/Versions/"
        for path in executables {
            if ["/usr/bin/ssh", "/usr/sbin/sshd", "/usr/libexec/sshd-session"].contains(path) { return nil }
            if path.hasPrefix(rexServerRoot), path.hasSuffix("/Rex Server.app/Contents/MacOS/rex") {
                return "com.superlogical.rex"
            }
            for root in applications {
                for name in ["Rex.app", "Rex Beta.app"] where path == root + name + "/Contents/Helpers/Rex Server.rex/Contents/MacOS/rex" {
                    return "com.superlogical.rex"
                }
                if path == root + "Zed.app/Contents/MacOS/zed" { return "dev.zed.Zed" }
                if path == root + "Zed Preview.app/Contents/MacOS/zed" { return "dev.zed.Zed-Preview" }
            }
        }
        return nil
    }

    public static func enriching(_ object: [String: Any], environment: [String: String],
                                 ancestor: @autoclosure () -> String? = nil) -> [String: Any] {
        var result = object
        if result["terminal_bundle_id"] == nil, result["terminalBundleID"] == nil,
           environment["SSH_CONNECTION"] == nil, environment["SSH_TTY"] == nil,
           let bundle = bundleID(environment: environment) ?? ancestor() {
            result["terminal_bundle_id"] = bundle
        }
        if (result["terminal_bundle_id"] ?? result["terminalBundleID"]) as? String == "com.superlogical.rex",
           environment["SSH_CONNECTION"] == nil, environment["SSH_TTY"] == nil,
           environment["TMUX"] == nil, environment["STY"] == nil,
           result["rex_session_id"] == nil, result["rex_block_id"] == nil,
           let session = environment["REX_SESSION"], session.hasPrefix("session:"),
           UUID(uuidString: String(session.dropFirst(8))) != nil,
           let block = environment["REX_BLOCK"], block.hasPrefix("block:"),
           UUID(uuidString: String(block.dropFirst(6))) != nil {
            result["rex_session_id"] = session
            result["rex_block_id"] = block
        }
        return result
    }
}
