import XCTest
@testable import SINotchCore

final class SessionOriginTests: XCTestCase {
    func testKnownTerminalPrograms() {
        for (program, bundle) in ["ghostty": "com.mitchellh.ghostty", "Apple_Terminal": "com.apple.Terminal",
                                  "iTerm.app": "com.googlecode.iterm2", "vscode": "com.microsoft.VSCode",
                                  "WezTerm": "com.github.wez.wezterm", "WarpTerminal": "dev.warp.Warp-Stable"] {
            XCTAssertEqual(SessionOrigin.bundleID(environment: ["TERM_PROGRAM": program]), bundle)
        }
    }

    func testEditorBundleDisambiguatesIntegratedTerminal() {
        XCTAssertEqual(SessionOrigin.bundleID(environment: ["TERM_PROGRAM": "vscode",
            "__CFBundleIdentifier": "com.todesktop.230313mzl4w4u92"]), "com.todesktop.230313mzl4w4u92")
        XCTAssertEqual(SessionOrigin.bundleID(environment: ["TERM_PROGRAM": "ghostty",
            "__CFBundleIdentifier": "unrecognized.app"]), "com.mitchellh.ghostty")
        XCTAssertNil(SessionOrigin.bundleID(environment: ["TERM_PROGRAM": "unknown"]))
    }

    func testSSHDoesNotIdentifyRemoteTerminalAsLocal() {
        for key in ["SSH_CONNECTION", "SSH_TTY"] {
            XCTAssertNil(SessionOrigin.bundleID(environment: [key: "remote", "TERM_PROGRAM": "ghostty",
                "__CFBundleIdentifier": "com.mitchellh.ghostty"]))
        }
    }

    func testExplicitOriginIsPreservedAndEnvironmentIsNotForwarded() {
        let environment = ["TERM_PROGRAM": "ghostty", "API_KEY": "do-not-forward"]
        let inferred = SessionOrigin.enriching(["event": "agent.working"], environment: environment)
        XCTAssertEqual(inferred.count, 2)
        XCTAssertEqual(inferred["terminal_bundle_id"] as? String, "com.mitchellh.ghostty")
        for key in ["terminal_bundle_id", "terminalBundleID"] {
            let explicit = SessionOrigin.enriching([key: "custom.app"], environment: environment)
            XCTAssertEqual(explicit.count, 1)
            XCTAssertEqual(explicit[key] as? String, "custom.app")
        }
    }
}
