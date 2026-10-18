import CryptoKit
import Foundation

/// One-off operator tool for a packaged si-notch.app. Compile together with
/// CodexHookSetup.swift; preview the exact merge before invoking apply.
@main
enum CodexHookSetupRunner {
    static func main() {
        do {
            let args = CommandLine.arguments
            guard (5...6).contains(args.count), (args[1] == "preview" || args[1] == "apply") else {
                throw RunnerError.usage
            }
            let adapter = args[2], helper = args[3]
            let hooksURL = args.count == 6 ? URL(fileURLWithPath: args[5])
                : FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/hooks.json")
            let setup = CodexHookSetup(adapterPath: adapter, helperPath: helper, hooksURL: hooksURL)
            let preview = try setup.preview()
            let digest = SHA256.hash(data: Data(preview.proposedJSON.utf8))
                .map { String(format: "%02x", $0) }.joined()
            switch args[1] {
            case "preview":
                let output = URL(fileURLWithPath: args[4])
                guard output.path.hasPrefix("/"), !FileManager.default.fileExists(atPath: output.path) else {
                    throw RunnerError.outputExists
                }
                try Data(preview.proposedJSON.utf8).write(to: output, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: output.path)
                print("Preview: \(output.path)")
                print("SHA-256: \(digest)")
                print("Events to add: \(preview.addedEvents.count)")
            case "apply":
                guard args[4] == digest else { throw RunnerError.previewMismatch }
                guard preview.canApply else { throw RunnerError.alreadyInstalled }
                let backup = try setup.apply(preview)
                print("Applied Codex hook merge to \(preview.hooksURL.path)")
                if let backup { print("Backup: \(backup.path)") }
                print("Next: in Codex CLI, run /hooks and review/trust the new definitions.")
            default: throw RunnerError.usage
            }
        } catch {
            fputs("Codex hook setup: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    private enum RunnerError: LocalizedError {
        case usage, outputExists, previewMismatch, alreadyInstalled
        var errorDescription: String? {
            switch self {
            case .usage:
                return "Usage: runner preview ADAPTER HELPER NEW_PREVIEW_FILE [HOOKS_FILE] | runner apply ADAPTER HELPER REVIEWED_SHA256 [HOOKS_FILE]"
            case .outputExists: return "The preview file already exists; choose a new private path."
            case .previewMismatch: return "The proposed merge differs from the reviewed SHA-256; preview again."
            case .alreadyInstalled: return "These Codex hooks are already present."
            }
        }
    }
}
