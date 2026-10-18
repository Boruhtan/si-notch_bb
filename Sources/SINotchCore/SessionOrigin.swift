import Foundation

/// Identifies the local host without reading process arguments or credentials.
public enum SessionOrigin {
    private static let terminals = [
        "apple_terminal": "com.apple.Terminal",
        "iterm.app": "com.googlecode.iterm2",
        "ghostty": "com.mitchellh.ghostty",
        "wezterm": "com.github.wez.wezterm",
        "vscode": "com.microsoft.VSCode",
        "warpterminal": "dev.warp.Warp-Stable"
    ]
    private static let knownBundles: Set<String> = Set(terminals.values).union([
        "com.microsoft.VSCodeInsiders", "com.todesktop.230313mzl4w4u92", "dev.zed.Zed",
        "dev.zed.Zed-Preview", "com.openai.codex", "net.kovidgoyal.kitty", "org.alacritty"
    ])

    public static func bundleID(environment: [String: String]) -> String? {
        guard environment["SSH_CONNECTION"] == nil, environment["SSH_TTY"] == nil else { return nil }
        if let bundle = environment["__CFBundleIdentifier"], knownBundles.contains(bundle) { return bundle }
        return environment["TERM_PROGRAM"].flatMap { terminals[$0.lowercased()] }
    }

    public static func enriching(_ object: [String: Any], environment: [String: String]) -> [String: Any] {
        var result = object
        if result["terminal_bundle_id"] == nil, result["terminalBundleID"] == nil,
           let bundle = bundleID(environment: environment) {
            result["terminal_bundle_id"] = bundle
        }
        return result
    }
}
